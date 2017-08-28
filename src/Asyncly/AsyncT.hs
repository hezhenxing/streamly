{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE EmptyCase                 #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE UndecidableInstances      #-} -- XXX

-- |
-- Module      : Asyncly.AsyncT
-- Copyright   : (c) 2017 Harendra Kumar
--
-- License     : MIT-style
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC
--
--
module Asyncly.AsyncT
    ( AsyncT (..)
    , MonadAsync
--    , async
--    , makeAsync
    )
where

import           Control.Applicative         (Alternative (..))
import           Control.Concurrent          (ThreadId, forkIO, killThread,
                                              myThreadId, threadDelay)
import           Control.Concurrent.STM      (TBQueue, atomically, newTBQueue,
                                              tryReadTBQueue, writeTBQueue,
                                              isEmptyTBQueue, isFullTBQueue,
                                              peekTBQueue)
import           Control.Exception           (SomeException (..))
import qualified Control.Exception.Lifted    as EL
import           Control.Monad               (ap, liftM, MonadPlus(..), mzero,
                                              when)
import           Control.Monad.Base          (MonadBase (..), liftBaseDefault)
import           Control.Monad.Catch         (MonadThrow, throwM)
import           Control.Monad.IO.Class      (MonadIO(..))
import           Control.Monad.Trans.Class   (MonadTrans (lift))
import           Control.Monad.Trans.Control (MonadBaseControl, liftBaseWith)
import           Data.Functor                (void)
import           Data.IORef                  (IORef, modifyIORef, newIORef,
                                              writeIORef, readIORef)
import           Data.Monoid                 ((<>))
import           Data.Set                    (Set)
import qualified Data.Set                    as S

import           Control.Monad.Trans.Recorder (MonadRecorder(..))


------------------------------------------------------------------------------
-- Concurrency Semantics
------------------------------------------------------------------------------
--
-- Asyncly is essentially a concurrent list transformer. To concatenate the
-- lists it provides three different ways of composing them. The Monoid
-- instance concatenates lists in a non-concurrent in-order fashion. The
-- Alternative instance concatenates list in a concurrent manner potentially
-- running each action in parallel and therefore the order of the resulting
-- items is not deterministic. Computations in Alternative composition may or
-- may not run in parallel. Thirdly, the <||> operator provides a way to
-- compose computations that are guaranteed to run in parallel. This provides a
-- way to run infinite loops or long running computations without blocking
-- or starving other computations.

------------------------------------------------------------------------------
-- Parent child thread communication types
------------------------------------------------------------------------------

data ChildEvent a =
      ChildYield a
    | ChildDone ThreadId a
    | ChildStop ThreadId (Maybe SomeException)
    | ChildCreate ThreadId

------------------------------------------------------------------------------
-- State threaded around the monad for thread management
------------------------------------------------------------------------------

data Context m a =
    Context { outputQueue    :: TBQueue (ChildEvent a)
            , workQueue      :: TBQueue (AsyncT m a)
            , runningThreads :: IORef (Set ThreadId)
            , doneThreads    :: IORef (Set ThreadId)
            }

-- The 'Maybe (AsyncT m a)' is redundant as we can use 'stop' value for the
-- Nothing case, but it makes the fold using '<|>' 25% faster. Need to try
-- again as the code has gone through many changes after this was tested.
-- With the Maybe, 'stop' is required only to represent 'empty' in an
-- Alternative composition.
--
-- Currently the only state we need is the thread context, For generality we
-- can parameterize the type with a state type 's'.
newtype AsyncT m a =
    AsyncT {
        runAsyncT :: forall r.
               Maybe (Context m a)                          -- state
            -> m r                                          -- stop
            -> (a -> Maybe (Context m a) -> Maybe (AsyncT m a) -> m r)  -- yield
            -> m r
    }

type MonadAsync m = (MonadIO m, MonadBaseControl IO m, MonadThrow m)

------------------------------------------------------------------------------
-- Monad
------------------------------------------------------------------------------

-- | Appends the results of two AsyncT computations in order.
instance Monad m => Monoid (AsyncT m a) where
    mempty = AsyncT $ \_ stp _ -> stp
    mappend (AsyncT m1) m2 = AsyncT $ \ctx stp yld ->
        let stop = (runAsyncT m2) ctx stp yld
            yield a c Nothing  = yld a c (Just m2)
            yield a c (Just r) = yld a c (Just (mappend r m2))
        in m1 ctx stop yield

-- We do not use bind for parallelism. That is, we do not start each iteration
-- of the list in parallel. That will introduce too much uncontrolled
-- parallelism. Instead we control parallelism using <|>, it is used for
-- actions that 'may' be run in parallel. The library decides whether they will
-- be started in parallel. This puts the parallel semantics in the hands of the
-- user and operational semantics in the hands of the library. Ideally we would
-- want parallelism to be completely hidden from the user, for example we can
-- automatically decide where to start an action in parallel so that it is most
-- efficient. We can decide whether a particular bind should fork a parallel
-- thread or not based on the level of the bind in the tree. Maybe at some
-- point we shall be able to do that?

instance Monad m => Monad (AsyncT m) where
    return a = AsyncT $ \ctx _ yld -> yld a ctx Nothing

    -- | A thread context is valid only until the next bind. Upon a bind we
    -- reset the context to Nothing.
    AsyncT m >>= f = AsyncT $ \_ stp yld ->
        let run x = (runAsyncT x) Nothing stp yld
            yield a _ Nothing  = run $ f a
            yield a _ (Just r) = run $ f a <> (r >>= f)
        in m Nothing stp yield

------------------------------------------------------------------------------
-- Functor
------------------------------------------------------------------------------

instance Monad m => Functor (AsyncT m) where
    fmap = liftM

------------------------------------------------------------------------------
-- Applicative
------------------------------------------------------------------------------

instance Monad m => Applicative (AsyncT m) where
    pure  = return
    (<*>) = ap

------------------------------------------------------------------------------
-- Alternative
------------------------------------------------------------------------------

{-# INLINE doFork #-}
doFork :: (MonadIO m, MonadBaseControl IO m)
    => m ()
    -> (SomeException -> IO ())
    -> m ThreadId
doFork action exHandler =
    EL.mask $ \restore ->
        liftBaseWith $ \runInIO -> forkIO $ do
            -- XXX test the exception handling
            _ <- runInIO $ EL.catch (restore action) (liftIO . exHandler)
            -- XXX restore state here?
            return ()

{-# NOINLINE push #-}
push :: MonadAsync m => Context m a -> m ()
push ctx = run (Just ctx) (dequeueLoop ctx)

    where

    send msg = atomically $ writeTBQueue (outputQueue ctx) msg
    stop = do
        workQEmpty <- liftIO $ atomically $ isEmptyTBQueue (workQueue ctx)
        if (not workQEmpty) then push ctx
        else liftIO $ myThreadId >>= \tid -> send (ChildStop tid Nothing)
    yield a _ Nothing  = liftIO $ myThreadId >>= \tid -> send (ChildDone tid a)
    yield a c (Just r) = liftIO (send (ChildYield a)) >> run c r
    run c m            = (runAsyncT m) c stop yield

-- Thread tracking has a significant performance overhead (~20% on empty
-- threads, it will be lower for heavy threads). It is needed for two reasons:
--
-- 1) Killing threads on exceptions. Threads may not be allowed to go away by
-- themselves because they may run for significant times before going away or
-- worse they may be stuck in IO and never go away.
--
-- 2) To know when all threads are done. This can be acheived by detecting a
-- BlockedIndefinitelyOnSTM exception too. But we will have to trigger a GC to
-- make sure that we detect it promptly.
--
-- This is a bit messy because ChildCreate and ChildDone events can arrive out
-- of order in case of pushSideDispatch. Returns whether we are done draining
-- threads.
{-# INLINE accountThread #-}
accountThread :: MonadIO m
    => ThreadId -> IORef (Set ThreadId) -> IORef (Set ThreadId) -> m Bool
accountThread tid ref1 ref2 = liftIO $ do
    s1 <- readIORef ref1
    s2 <- readIORef ref2

    if (S.member tid s1) then do
        let r = S.delete tid s1
        writeIORef ref1 r
        return $ S.null r && S.null s2
    else do
        liftIO $ writeIORef ref2 (S.insert tid s2)
        return False

{-# NOINLINE addThread #-}
addThread :: MonadIO m => Context m a -> ThreadId -> m Bool
addThread ctx tid = accountThread tid (doneThreads ctx) (runningThreads ctx)

{-# INLINE delThread #-}
delThread :: MonadIO m => Context m a -> ThreadId -> m Bool
delThread ctx tid = accountThread tid (runningThreads ctx) (doneThreads ctx)

handleException :: (MonadIO m, MonadThrow m)
    => SomeException -> Context m a -> ThreadId -> m r
handleException e ctx tid = do
    void (delThread ctx tid)
    liftIO $ readIORef (runningThreads ctx) >>= mapM_ killThread
    throwM e

-- We re-raise any exceptions received from the child threads, that way
-- exceptions get propagated to the top level computation and can be handled
-- there.
{-# NOINLINE pullWorker #-}
pullWorker :: MonadAsync m => Context m a -> AsyncT m a
pullWorker ctx = AsyncT $ \pctx stp yld -> do
    let continue = (runAsyncT (pullWorker ctx)) pctx stp yld
        yield a  = yld a pctx (Just (pullWorker ctx))
        threadOp tid f finish cont = do
            done <- f ctx tid
            if done then finish else cont

    res <- liftIO $ atomically $ tryReadTBQueue (outputQueue ctx)
    case res of
        Nothing -> do
            liftIO $ threadDelay 4
            let workQ = workQueue ctx
                outQ  = outputQueue ctx
            workQEmpty <- liftIO $ atomically $ isEmptyTBQueue workQ
            outQEmpty  <- liftIO $ atomically $ isEmptyTBQueue outQ
            when (not workQEmpty && outQEmpty) $ pushWorker ctx
            void $ liftIO $ atomically $ peekTBQueue (outputQueue ctx)
            continue
        Just ev ->
            case ev of
                ChildYield a -> yield a
                ChildDone tid a ->
                    threadOp tid delThread (yld a pctx Nothing) (yield a)
                ChildStop tid e ->
                    case e of
                        Nothing -> threadOp tid delThread stp continue
                        Just ex -> handleException ex ctx tid
                ChildCreate tid -> threadOp tid addThread stp continue

-- If an exception occurs we push it to the channel so that it can handled by
-- the parent.  'Paused' exceptions are to be collected at the top level.
-- XXX Paused exceptions should only bubble up to the runRecorder computation
{-# NOINLINE handleChildException #-}
handleChildException :: TBQueue (ChildEvent a) -> SomeException -> IO ()
handleChildException pchan e = do
    tid <- myThreadId
    atomically $ writeTBQueue pchan (ChildStop tid (Just e))

-- This function is different than "forkWorker" because we have to directly
-- insert the threadIds here and cannot use the channel to send ChildCreate
-- unlike on the push side.  If we do that, the first thread's done message
-- may arrive even before the second thread is forked, in that case
-- pullWorker will falsely detect that all threads are over.
{-# INLINE pushWorker #-}
pushWorker :: MonadAsync m => Context m a -> m ()
pushWorker ctx = do
    tid <- doFork (push ctx) (handleChildException (outputQueue ctx))
    liftIO $ modifyIORef (runningThreads ctx) $ (\s -> S.insert tid s)

-- | Split the original computation in a pull-push pair. The original
-- computation pulls from a Channel while m1 and m2 push to the channel.
{-# NOINLINE pullFork #-}
pullFork :: MonadAsync m => AsyncT m a -> AsyncT m a -> AsyncT m a
pullFork m1 m2 = AsyncT $ \_ stp yld -> do
    ctx <- liftIO $ newContext
    queueWork ctx m1 >> queueWork ctx m2 >> pushWorker ctx
    (runAsyncT (pullWorker ctx)) Nothing stp yld

    where

    newContext = do
        outQ    <- atomically $ newTBQueue 32
        workQ   <- atomically $ newTBQueue 32
        running <- newIORef S.empty
        done    <- newIORef S.empty
        return $ Context { outputQueue   = outQ
                         , runningThreads = running
                         , doneThreads    = done
                         , workQueue      = workQ
                         }

-- Concurrency rate control. Our objective is to create more threads on
-- demand if the consumer is running faster than us. As soon as we
-- encounter an Alternative composition we create a push pull pair of
-- threads. We use a channel for communication between the consumer that
-- pulls from the channel and the producer that pushes to the channel. The
-- producer creates more threads if the channel becomes empty at times,
-- that is the consumer is running faster. However this mechanism can be
-- problematic if the initial production latency is high, we may end up
-- creating too many threads. So we need some way to monitor and use the
-- latency as well.
--
-- TBD For quick response we may have to increase the rate in the middle of
-- a serially running computation. For that we can use a state flag to fork
-- the rest of the computation at any point of time inside the Monad bind
-- operation if the consumer is running at a faster speed.
--
-- TBD the alternative composition allows us to dispatch a chunkSize of only 1.
-- If we have to dispatch in arbitrary chunksizes we will need to compose the
-- parallel actions using a data constructor instead so that we can divide it
-- in chunks of arbitrary size before dispatch. When batching we can convert
-- the structure into Alternative batches of Monoid composition. That will also
-- allow us to dispatch more work to existing threads rather than creating new
-- threads always.
--
-- TBD for pure work (when we are not in the IO monad) we can divide it into
-- just the number of CPUs.
--
-- XXX to rate control left folded structrues we will have to return the
-- residual work back to the dispatcher. It will also consume a lot of
-- memory due to queueing of all the work before execution starts.

{-# INLINE forkWorker #-}
forkWorker :: MonadAsync m => Context m a -> m ()
forkWorker ctx = do
    let q = outputQueue ctx
    tid <- doFork (push ctx) (handleChildException q)
    liftIO $ atomically $ writeTBQueue q (ChildCreate tid)

{-# INLINE queueWork #-}
queueWork :: MonadAsync m => Context m a -> AsyncT m a -> m ()
queueWork ctx m = do
    -- To guarantee deadlock avoidance we need to dispatch a worker when the
    -- workQueue goes full. Otherwise all the worker threads might be waiting
    -- on the queue and never wakeup.
    --
    -- TBD If we run out of threads we can also evaluate the action completely
    -- right here, disallowing any further child workers and turning the
    -- parallel composition into interleaved serial composition.
    workQFull <- liftIO $ atomically $ isFullTBQueue (workQueue ctx)
    when (workQFull) $ forkWorker ctx
    liftIO $ atomically $ writeTBQueue (workQueue ctx) m

{-# INLINE dequeueLoop #-}
dequeueLoop :: MonadAsync m => Context m a -> AsyncT m a
dequeueLoop ctx = AsyncT $ \_ stp yld -> do
    work <- liftIO $ atomically $ tryReadTBQueue (workQueue ctx)
    case work of
        Nothing -> stp
        Just m -> do
            let stop = (runAsyncT (dequeueLoop ctx)) Nothing stp yld
                yield a c Nothing = yld a c (Just (dequeueLoop ctx))
                yield a c r = yld a c r
            (runAsyncT m) (Just ctx) stop yield

instance MonadAsync m => Alternative (AsyncT m) where
    empty = mempty

    -- Note: This is designed to scale for right associated compositions,
    -- therefore always use a right fold for folding bigger structures.
    {-# INLINE (<|>) #-}
    m1 <|> m2 = AsyncT $ \ctx stp yld -> do
        case ctx of
            Nothing -> (runAsyncT (pullFork m1 m2)) Nothing stp yld
            Just  c -> do
                -- we open up both the branches fairly but on a given level we
                -- go left to right. If the left one keeps producing results we
                -- may or may not run the right one.
                queueWork c m1 >> queueWork c m2
                (runAsyncT (dequeueLoop c)) Nothing stp yld

instance MonadAsync m => MonadPlus (AsyncT m) where
    mzero = empty
    mplus = (<|>)

------------------------------------------------------------------------------
-- Num
------------------------------------------------------------------------------

instance (Num a, Monad (AsyncT m)) => Num (AsyncT m a) where
  fromInteger = return . fromInteger
  mf + mg     = (+) <$> mf <*> mg
  mf * mg     = (*) <$> mf <*> mg
  negate f    = f >>= return . negate
  abs f       = f >>= return . abs
  signum f    = f >>= return . signum

-------------------------------------------------------------------------------
-- AsyncT transformer
-------------------------------------------------------------------------------

instance MonadTrans AsyncT where
    lift mx = AsyncT $ \ctx _ yld -> mx >>= (\a -> (yld a ctx Nothing))

instance (MonadBase b m, Monad m) => MonadBase b (AsyncT m) where
    liftBase = liftBaseDefault

------------------------------------------------------------------------------
-- Standard transformer instances
------------------------------------------------------------------------------

instance MonadIO m => MonadIO (AsyncT m) where
    liftIO = lift . liftIO

instance MonadThrow m => MonadThrow (AsyncT m) where
    throwM = lift . throwM

------------------------------------------------------------------------------
-- MonadRecorder
------------------------------------------------------------------------------

instance MonadRecorder m => MonadRecorder (AsyncT m) where
    getJournal = lift getJournal
    putJournal = lift . putJournal
    play = lift . play

------------------------------------------------------------------------------
-- Async primitives
------------------------------------------------------------------------------
--
-- Only those actions that are marked with 'async' are guaranteed to be
-- asynchronous. Asyncly is free to run other actions synchronously or
-- asynchronously and it should not matter to the semantics of the program, if
-- it does then use async to force.
--
-- Why not make async as default and ask the programmer to use a 'sync'
-- primitive to force an action to run synchronously? But then we would not
-- have the freedom to convert the async actions to sync dynamically. Note that
-- it is safe to convert a sync action to async but vice-versa is not true.
-- Converting an async to sync can cause change in semantics if the async
-- action was an infinite loop for example.
--
-- | In an 'Alternative' composition, force the action to run asynchronously.
-- The @\<|\>@ operator implies "can be parallel", whereas 'async' implies
-- "must be parallel". Note that outside an 'Alternative' composition 'async'
-- is not useful and should not be used.  Even in an 'Alternative' composition
-- 'async' is not useful as the last action as the last action always runs in
-- the current thread.
{-
async :: Monad m => AsyncT m a -> AsyncT m a
async action = AsyncT $ runAsyncTask True (runAsyncT action)

makeAsync :: Monad m => ((a -> m ()) -> m ()) -> AsyncT m a
makeAsync = AsyncT . makeCont
-}
