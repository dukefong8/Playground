{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE GHC2024           #-}
{-# LANGUAGE OverloadedStrings #-}

module Logger
  ( cleanupLogger
  , logger
  ) where

import System.IO.Unsafe (unsafePerformIO)
import System.Log.FastLogger (FastLogger, LogStr, LogType' (LogStdout), defaultBufSize, newFastLogger, toLogStr)

import Colog (LogAction (..), LoggerT, Message, cmap, fmtMessage, usingLoggerT)

fastLogger :: (FastLogger, IO ())
fastLogger = unsafePerformIO $ newFastLogger (LogStdout defaultBufSize)
{-# NOINLINE fastLogger #-}

logStdout :: FastLogger
logStdout = fst fastLogger

cleanupLogger :: IO ()
cleanupLogger = snd fastLogger

-- | Bridges a fast-logger function into a co-log LogAction
fastLoggerAction :: MonadIO m => FastLogger -> LogAction m LogStr
fastLoggerAction logger' = LogAction $ \logStr -> liftIO $ logger' logStr

fmtLogStr :: Message -> LogStr
fmtLogStr = toLogStr . (<> "\n") . fmtMessage

logger :: MonadIO m => LoggerT Message m a -> m a
logger = usingLoggerT $ cmap fmtLogStr (fastLoggerAction logStdout)
