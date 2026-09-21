{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE GHC2024           #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The app logger: fast-logger behind colog actions, plus the handle the
-- server closes on shutdown.
module Service.Logger
  ( logDebug
  , logInfo
  , logError
  , closeLogger
  , silenceLogger
  ) where

import Colog.Core.Action (LogAction (..), cmap)
import Colog.Message qualified as Colog
import Colog.Monad (LoggerT, usingLoggerT)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Data.Text (Text)
import GHC.Stack (HasCallStack, withFrozenCallStack)
import System.IO.Unsafe (unsafePerformIO)
import System.Log.FastLogger (FastLogger, LogStr, LogType' (LogStdout), defaultBufSize, newFastLogger, toLogStr)

fastLogger :: (FastLogger, IO ())
fastLogger = unsafePerformIO $ newFastLogger (LogStdout defaultBufSize)
{-# NOINLINE fastLogger #-}

-- | Where log lines go: the stdout fast-logger in production, nothing under
-- test. One per process — the same shape as 'Service.Grace.installed'.
installed :: IORef (LogStr -> IO ())
installed = unsafePerformIO (newIORef (fst fastLogger))
{-# NOINLINE installed #-}

-- | Drop all log lines. Tests call this before exercising routes so captured
-- test output stays results only; the server never calls it.
silenceLogger :: IO ()
silenceLogger = writeIORef installed (const (pure ()))

loggerAction :: MonadIO m => FastLogger -> LogAction m LogStr
loggerAction logger' = LogAction $ \logStr -> liftIO $ logger' logStr

fmtLogStr :: Colog.Message -> LogStr
fmtLogStr = toLogStr . (<> "\n") . Colog.fmtMessage

runLogger :: MonadIO m => LoggerT Colog.Message m a -> m a
runLogger action = do
  sink <- liftIO (readIORef installed)
  usingLoggerT (cmap fmtLogStr (loggerAction sink)) action

closeLogger :: IO ()
closeLogger = snd fastLogger

logDebug :: (HasCallStack, MonadIO m) => Text -> m ()
logDebug msg = withFrozenCallStack $ runLogger $ Colog.logDebug msg

logInfo :: (HasCallStack, MonadIO m) => Text -> m ()
logInfo msg =  withFrozenCallStack $ runLogger $ Colog.logInfo msg

logError :: (HasCallStack, MonadIO m) => Text -> m ()
logError msg = withFrozenCallStack $ runLogger $ Colog.logError msg
