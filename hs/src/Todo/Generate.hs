{-# LANGUAGE GHC2024           #-}
{-# LANGUAGE OverloadedStrings #-}

-- | What this feature asks the model for: three concise todo titles.
--
-- The runner lives in "Service.Grace" — one per process, stubbed in tests — so
-- this module is only the prompt and the wiring from a request's text to a Grace
-- program. It names one input, @todoPrompt@, which the program interpolates.
module Todo.Generate
  ( runGenerateTodoTitles
  ) where

import Service.Grace qualified as Grace
import Service.Http (RouteHandler)

-- | Ask for todo titles through whichever runner is installed.
runGenerateTodoTitles :: Text -> RouteHandler (Either Text [Text])
runGenerateTodoTitles promptText =
  Grace.run [("todoPrompt", promptText)] todoTitlesProgram

-- | The program: DeepSeek, the user's key, and the request for three titles.
todoTitlesProgram :: Text
todoTitlesProgram = unlines
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
