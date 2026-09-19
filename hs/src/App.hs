{-# LANGUAGE BlockArguments      #-}
{-# LANGUAGE GHC2024             #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE TemplateHaskell     #-}

module App
  ( app
  , appWithTodoGenerator
  ) where

import App.Todo
import Data.ByteString.Lazy qualified as LBS
import Database
import Embedded (todoFilterEntries)
import Htmx
import Http
import IHP.Router.Trie (mergeTrie)
import IHP.Router.WAI (HasPath (..), UrlCapture (..), routeTrieMiddleware, routes)
import Language.Haskell.TH.Syntax (addDependentFile)
import Network.HTTP.Types (StdMethod (..), status200, status404)
import Network.Wai (Application, Request, Response, ResponseReceived)
import Network.Wai.Application.Static (staticApp)
import Prelude hiding (id)
import WaiAppStatic.Storage.Embedded (mkSettings)
import WaiAppStatic.Types (MaxAge (NoStore), StaticSettings, ssMaxAge)
import Web.FormUrlEncoded (FromForm)

data HomeRoute = HomeAction
  deriving (Eq, Show)

-- | The todo filter's client source, embedded at compile time and served through
-- wai-app-static. @addDependentFile@ records the @.cljs@ as a dependency of this
-- module, so editing the filter recompiles it — without that, GHC would see no
-- Haskell change and keep serving the previous embedding.
todoFilterStatic :: StaticSettings
todoFilterStatic =
  ( $( do
        addDependentFile "static/todo-filter.cljs"
        mkSettings todoFilterEntries
    )
  )
    { ssMaxAge = NoStore }

$(pure []) -- declaration-group boundary

[routes|
GET /                         HomeAction
GET /todos                    TodosPageAction
GET /todos/list               TodoListAction
GET /todo-filter.cljs         TodoFilterScriptAction
POST /todos                   AddTodoAction
POST /todos/clear             ClearTodosAction
PATCH /todos/{id}             ToggleTodoAction { todoId = #id }
DELETE /todos/{id}            DeleteTodoAction { todoId = #id }
GET /todos/{id}/edit          EditTodoAction { todoId = #id }
PUT /todos/{id}               UpdateTodoAction { todoId = #id }
POST /todos/generate          GenerateTodosAction
|]

app :: Pool -> Application
app = appWithTodoGenerator graceGenerateTodoTitles

appWithTodoGenerator :: GenerateTodoTitles -> Pool -> Application
appWithTodoGenerator generate pool =
  routeTrieMiddleware
    (mergeTrie (homeRouteTrie dispatchHome) (todoRouteTrie (dispatchTodo generate pool)))
    notFoundApplication

dispatchHome :: HomeRoute -> Application
dispatchHome HomeAction _req respond =
  respond $ htmlResponse status200 $ renderBS index

dispatchTodo :: GenerateTodoTitles -> Pool -> TodoRoute -> Application
dispatchTodo _generate pool TodosPageAction req respond =
  runView renderTodosViewHtml (getTodosPage pool) req respond
dispatchTodo _generate pool TodoListAction req respond =
  runView renderTodoListViewHtml (getTodoListPartial pool) req respond
dispatchTodo _generate _pool TodoFilterScriptAction req respond =
  staticApp todoFilterStatic req respond
dispatchTodo _generate pool AddTodoAction req respond =
  withParsedBody req (addTodo pool) renderTodoMutationViewHtml respond
dispatchTodo _generate pool ClearTodosAction req respond =
  runView renderTodoMutationViewHtml (clearCompleted pool) req respond
dispatchTodo _generate pool (ToggleTodoAction rawId) req respond =
  case routeTodoIdOr404 rawId of
    Left response -> respond response
    Right todoId  -> runView renderTodoMutationViewHtml (toggleTodo pool todoId) req respond
dispatchTodo _generate pool (DeleteTodoAction rawId) _req respond =
  case routeTodoIdOr404 rawId of
    Left response -> respond response
    Right todoId  -> runView renderTodoMutationViewHtml (deleteTodo pool todoId) _req respond
dispatchTodo _generate pool (EditTodoAction rawId) _req respond =
  case routeTodoIdOr404 rawId of
    Left response -> respond response
    Right todoId  -> runView renderTodoEditViewHtml (editTodoForm pool todoId) _req respond
dispatchTodo _generate pool (UpdateTodoAction rawId) req respond =
  case routeTodoIdOr404 rawId of
    Left response -> respond response
    Right todoId  -> withParsedBody req (updateTodo pool todoId) renderTodoMutationViewHtml respond
dispatchTodo generate pool GenerateTodosAction req respond =
  withParsedBody req (generateTodos pool generate) renderTodoMutationViewHtml respond

routeTodoIdOr404 :: Integer -> Either Response TodoId
routeTodoIdOr404 rawId =
  case toTodoId rawId of
    Nothing     -> Left $ htmlResponse status404 $ renderBS page404
    Just todoId -> Right todoId

runView :: (a -> LBS.ByteString) -> RouteHandler a -> Application
runView renderHtml action req respond = do
  result <- runRouteHandler action
  respond case result of
    Left err    -> errorResponse err
    Right value -> viewResponse renderHtml value

withParsedBody :: FromForm a => Request -> (a -> RouteHandler b) -> (b -> LBS.ByteString) -> (Response -> IO ResponseReceived) -> IO ResponseReceived
withParsedBody req action renderHtml respond = do
  parsed <- runRouteHandler (parseRequestBody req)
  case parsed of
    Left err    -> respond (errorResponse err)
    Right value -> runView renderHtml (action value) req respond

index :: Html ()
index = [hsx|<h1>Welcome!</h1>|]

page404 :: Html ()
page404 = [hsx|<h1>Not found...</h1>|]

notFoundApplication :: Application
notFoundApplication _req respond =
  respond $ htmlResponse status404 $ renderBS page404
