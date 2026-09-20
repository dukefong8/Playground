{-# LANGUAGE BlockArguments      #-}
{-# LANGUAGE GHC2024             #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE TemplateHaskell     #-}

-- | The todo routes served through ihp-router, mounted at @/app@ by 'Site'.
-- The client script under @/static@ is served separately by 'Site.Static'.
module Todo.Route
  ( ihpApp
  ) where

import Network.HTTP.Types (StdMethod (..))
import Network.Wai (Application, Request, Response, ResponseReceived)
import Web.FormUrlEncoded (FromForm)

import Home.Route (notFoundResponse)
import Htmx.Prelude (Html, viewResponse)
import IHP.Router.Trie (mergeTrie)
import IHP.Router.WAI (HasPath (..), UrlCapture (..), routeTrieMiddleware, routes)
import Service.Hasql
import Service.Http
import Todo.Handler
import Todo.Type
import Todo.View

data TodoRoute
  = TodosPageAction
  | TodoListAction
  | AddTodoAction
  | ClearTodosAction
  | ToggleTodoAction { todoId :: Integer }
  | DeleteTodoAction { todoId :: Integer }
  | EditTodoAction { todoId :: Integer }
  | UpdateTodoAction { todoId :: Integer }
  | GenerateTodosAction
  deriving (Eq, Show)

-- | Links rendered into every ihp-served view.
ihpLinks :: TodoLinks
ihpLinks = todoLinks "/app"

$(pure []) -- declaration-group boundary

[routes|
GET /app/todos                    TodosPageAction
GET /app/todos/list               TodoListAction
POST /app/todos                   AddTodoAction
POST /app/todos/clear             ClearTodosAction
PATCH /app/todos/{id}             ToggleTodoAction { todoId = #id }
DELETE /app/todos/{id}            DeleteTodoAction { todoId = #id }
GET /app/todos/{id}/edit          EditTodoAction { todoId = #id }
PUT /app/todos/{id}               UpdateTodoAction { todoId = #id }
POST /app/todos/generate          GenerateTodosAction
|]

ihpApp :: Pool -> Application
ihpApp pool =
  routeTrieMiddleware
    (todoRouteTrie (dispatchTodo pool))
    notFoundApplication

dispatchTodo :: Pool -> TodoRoute -> Application
dispatchTodo pool TodosPageAction req respond =
  runView (todosViewHtml ihpLinks) (getTodosPage pool) req respond
dispatchTodo pool TodoListAction req respond =
  runView (todoListViewHtml ihpLinks) (getTodoListPartial pool) req respond
dispatchTodo pool AddTodoAction req respond =
  withParsedBody req (addTodo pool) (todoMutationViewHtml ihpLinks) respond
dispatchTodo pool ClearTodosAction req respond =
  runView (todoMutationViewHtml ihpLinks) (clearCompleted pool) req respond
dispatchTodo pool (ToggleTodoAction rawId) req respond =
  case routeTodoIdOr404 rawId of
    Left response -> respond response
    Right todoId  -> runView (todoMutationViewHtml ihpLinks) (toggleTodo pool todoId) req respond
dispatchTodo pool (DeleteTodoAction rawId) _req respond =
  case routeTodoIdOr404 rawId of
    Left response -> respond response
    Right todoId  -> runView (todoMutationViewHtml ihpLinks) (deleteTodo pool todoId) _req respond
dispatchTodo pool (EditTodoAction rawId) _req respond =
  case routeTodoIdOr404 rawId of
    Left response -> respond response
    Right todoId  -> runView (todoEditViewHtml ihpLinks) (editTodoForm pool todoId) _req respond
dispatchTodo pool (UpdateTodoAction rawId) req respond =
  case routeTodoIdOr404 rawId of
    Left response -> respond response
    Right todoId  -> withParsedBody req (updateTodo pool todoId) (todoMutationViewHtml ihpLinks) respond
dispatchTodo pool GenerateTodosAction req respond =
  withParsedBody req (generateTodos pool) (todoMutationViewHtml ihpLinks) respond

routeTodoIdOr404 :: Integer -> Either Response TodoId
routeTodoIdOr404 rawId =
  case toTodoId rawId of
    Nothing     -> Left notFoundResponse
    Just todoId -> Right todoId

runView :: (a -> Html ()) -> RouteHandler a -> Application
runView renderHtml action _req respond = do
  result <- runRouteHandler action
  respond case result of
    Left err    -> errorResponse err
    Right value -> viewResponse renderHtml value

withParsedBody :: FromForm a => Request -> (a -> RouteHandler b) -> (b -> Html ()) -> (Response -> IO ResponseReceived) -> IO ResponseReceived
withParsedBody req action renderHtml respond = do
  parsed <- runRouteHandler (parseRequestBody req)
  case parsed of
    Left err    -> respond (errorResponse err)
    Right value -> runView renderHtml (action value) req respond

notFoundApplication :: Application
notFoundApplication _req respond =
  respond notFoundResponse
