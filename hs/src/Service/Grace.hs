{-# LANGUAGE GHC2024           #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}

-- | The Grace (LLM) service: one runner per process, installed at load with the
-- call that really reaches Grace and replaced by tests.
--
-- What to ask stays with the caller — this module runs a program, it does not
-- know what the program is for. Threading a runner through every app builder to
-- reach one call site would be noise, so it lives here behind two functions
-- (callers run it, tests set it) and the 'IORef' never leaves this module.
module Service.Grace
  ( Inputs
  , Runner
  , run
  , setRunner
  , grace
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import System.IO.Unsafe (unsafePerformIO)

import Control.Exception qualified as Exception (SomeException, try)
import Grace.Input qualified (Input (Code))
import Grace.Interpret qualified as Grace (loadWith, (<~))

import Service.Http (RouteHandler)
import Service.Logger

-- | The values a program expects, by name. Text-only: a program run through here
-- is a prompt (see "Todo.Generate"), not a general Grace evaluator.
type Inputs = [(Text, Text)]

-- | A Grace program: the inputs bound when it runs, its source, and what it
-- yields — texts, or the message to show the user.
type Runner = Inputs -> Text -> IO (Either Text [Text])

installed :: IORef Runner
installed = unsafePerformIO (newIORef grace)
{-# NOINLINE installed #-}

-- | Run the installed runner — Grace in production, a stub under test.
run :: Inputs -> Text -> RouteHandler (Either Text [Text])
run inputs source = do
  runner <- liftIO (readIORef installed)
  liftIO (runner inputs source)

-- | Install a runner. Tests call this per session before exercising a generating
-- route; the server never calls it.
setRunner :: Runner -> IO ()
setRunner = writeIORef installed

-- | The production runner: load one Grace program with its inputs bound.
grace :: HasCallStack => Runner
grace inputs source = do
  result <- Exception.try @Exception.SomeException $
    Grace.loadWith (map (uncurry (Grace.<~)) inputs) (Grace.Input.Code "generation" source)
  case result of
    Left exc -> do
      logInfo $ "Grace generation failed: " <> T.show exc
      pure $ Left "grace generation failed"
    Right titles -> pure $ Right titles
