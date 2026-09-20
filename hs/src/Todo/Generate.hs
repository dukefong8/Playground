{-# LANGUAGE GHC2024           #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}

-- | The todo-title generator backend as a process-global.
--
-- The handler layer ('Todo.Handler.generateTodos') must not care which
-- backend answers: production serves Grace AI titles, tests stub canned
-- answers. Threading the backend through every app builder just to reach one
-- call site is noise, so it lives here behind two functions — readers run it,
-- tests set it — and the 'IORef' itself never leaves this module.
module Todo.Generate
  ( runGenerateTodoTitles
  , setGenerateTodoTitles
  , graceGenerateTodoTitles
  ) where

import Data.Text qualified as T
import System.IO.Unsafe (unsafePerformIO)

import Control.Exception qualified as Exception (SomeException, try)
import Grace.Input qualified (Input (Code))
import Grace.Interpret qualified as Grace (loadWith, (<~))
import Service.Http (RouteHandler)
import Service.Logger
import Todo.Type (GenerateTodoTitles)

todoTitlesGenerator :: IORef GenerateTodoTitles
todoTitlesGenerator = unsafePerformIO (newIORef graceGenerateTodoTitles)
{-# NOINLINE todoTitlesGenerator #-}

-- | Run whatever backend is currently installed (Grace in production, a stub
-- under test).
runGenerateTodoTitles :: Text -> RouteHandler (Either Text [Text])
runGenerateTodoTitles prompt = do
  generate <- liftIO (readIORef todoTitlesGenerator)
  generate prompt

-- | Install a backend. Tests call this per session before exercising the
-- generate routes; the production server never calls it.
setGenerateTodoTitles :: GenerateTodoTitles -> IO ()
setGenerateTodoTitles = writeIORef todoTitlesGenerator

graceGenerateTodoTitles :: HasCallStack => GenerateTodoTitles
graceGenerateTodoTitles promptText = do
  let graceSource = unlines
        [ "let key = env:DEEPSEEK_API_KEY : Key"
        , "let model = \"deepseek-v4-flash\""
        , "in  prompt"
        , "      { key"
        , "      , model"
        , "      , text: \""
        , "          Generate exactly 3 concise TodoMVC todo item titles for this request:"
        , ""
        , "          ${todoPrompt}"
        , ""
        , "          Return only actionable titles. Do not include numbering, bullets, or explanations."
        , "          \""
        , "      } : List Text"
        ]
  result <- liftIO $ Exception.try @Exception.SomeException $
    Grace.loadWith ["todoPrompt" Grace.<~ promptText] (Grace.Input.Code "todo-generation" graceSource)
  case result of
    Left exc -> do
      logInfo $ "Grace generation failed: " <> T.show exc
      pure $ Left "grace generation failed"
    Right titles -> pure $ Right titles
