{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GHC2024            #-}
{-# LANGUAGE NoFieldSelectors   #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE PatternSynonyms    #-}

-- | The todo routes served through servant record ('NamedRoutes') API,
-- mounted at @\/servant@ by 'Site'.
--
-- Every htmx route takes @Header "HX-Request" 'Htmx.Type.IsHtmxRequest'@:
-- servant parses it with the 'Htmx.Type' smart constructors, so malformed
-- htmx headers are rejected at the boundary while the handlers share the
-- exact 'Todo.Handler' logic (and 'Todo.View' rendering) with the
-- ihp-router stack in 'Todo.Route'.
module Todo.Servant
  ( servantApp
  ) where

import Prelude hiding (Handler)

import Data.ByteString.Lazy qualified as LBS
import GHC.Generics (Generic)
import Network.HTTP.Types (Status, hContentType, statusCode, statusMessage)
import Network.Wai (Application)

import Servant hiding (respond)
import Servant.API.Generic
import Servant.API.Raw (RawM)
import Servant.Server.Generic
import Servant.Server.Internal.Handler (pattern MkHandler)

import Home.Route (notFoundResponse)
import Home.View (page404)
import Htmx.Prelude (HTML, Html, IsHtmxRequest, htmlBody)
import Service.Hasql hiding (ServerError)
import Service.Http
import Todo.Handler
import Todo.Type
import Todo.View

-- | Links rendered into every servant-served view.
servantLinks :: TodoLinks
servantLinks = todoLinks "/servant"

-- | The htmx request contract, shared by every todo route.
type Hx = Header "HX-Request" IsHtmxRequest

data TodoApi mode = TodoApi
  { todosPage      :: mode :- "servant" :> "todos" :> Hx :> Get '[HTML] (Html ())
  , todoList       :: mode :- "servant" :> "todos" :> "list" :> Hx :> Get '[HTML] (Html ())
  , addTodo_       :: mode :- "servant" :> "todos" :> Hx :> ReqBody '[FormUrlEncoded] AddTodoRequest :> Post '[HTML] (Html ())
  , clearTodos     :: mode :- "servant" :> "todos" :> "clear" :> Hx :> Post '[HTML] (Html ())
  , generateTodos_ :: mode :- "servant" :> "todos" :> "generate" :> Hx :> ReqBody '[FormUrlEncoded] GenerateTodosRequest :> Post '[HTML] (Html ())
  , todoItem       :: mode :- "servant" :> "todos" :> Capture "id" Integer :> NamedRoutes TodoItemApi
  -- Last: anything unmatched under /servant is a 404 page, exactly like the
  -- ihp-router fallback. No HX-Request requirement here: unknown paths 404
  -- regardless of headers, and RawM answers any method the same way.
  , notFound_      :: mode :- "servant" :> CaptureAll "path" Text :> RawM
  } deriving stock Generic

data TodoItemApi mode = TodoItemApi
  { toggleTodo_   :: mode :- Hx :> Patch '[HTML] (Html ())
  , deleteTodo_   :: mode :- Hx :> Delete '[HTML] (Html ())
  , editTodoForm_ :: mode :- "edit" :> Hx :> Get '[HTML] (Html ())
  , updateTodo_   :: mode :- Hx :> ReqBody '[FormUrlEncoded] UpdateTodoRequest :> Put '[HTML] (Html ())
  } deriving stock Generic

servantApp :: Pool -> Application
servantApp pool = genericServe (todoServer pool)

todoServer :: Pool -> TodoApi AsServer
todoServer pool = TodoApi
  { todosPage = \_hxReq ->
      todosViewHtml servantLinks <$> runRouteHandlerServant (getTodosPage pool)
  , todoList = \_hxReq ->
      todoListViewHtml servantLinks <$> runRouteHandlerServant (getTodoListPartial pool)
  , addTodo_ = \_hxReq body ->
      todoMutationViewHtml servantLinks <$> runRouteHandlerServant (addTodo pool body)
  , clearTodos = \_hxReq ->
      todoMutationViewHtml servantLinks <$> runRouteHandlerServant (clearCompleted pool)
  , generateTodos_ = \_hxReq body ->
      todoMutationViewHtml servantLinks <$> runRouteHandlerServant (generateTodos pool body)
  , todoItem = todoItemServer pool
  , notFound_ = \_path req respond -> MkHandler (Right <$> notFoundApplication req respond)
  }

todoItemServer :: Pool -> Integer -> TodoItemApi AsServer
todoItemServer pool rawId = TodoItemApi
  { toggleTodo_ = withTodoId rawId $ \todoId _hxReq ->
      todoMutationViewHtml servantLinks <$> runRouteHandlerServant (toggleTodo pool todoId)
  , deleteTodo_ = withTodoId rawId $ \todoId _hxReq ->
      todoMutationViewHtml servantLinks <$> runRouteHandlerServant (deleteTodo pool todoId)
  , editTodoForm_ = withTodoId rawId $ \todoId _hxReq ->
      todoEditViewHtml servantLinks <$> runRouteHandlerServant (editTodoForm pool todoId)
  , updateTodo_ = \hxReq body ->
      withTodoId rawId (\todoId _ -> todoMutationViewHtml servantLinks <$> runRouteHandlerServant (updateTodo pool todoId body)) hxReq
  }

-- | Boundary-checked capture: out-of-range ids 404 with the shared page,
-- exactly like 'Todo.Route.routeTodoIdOr404'.
withTodoId :: Integer -> (TodoId -> Maybe IsHtmxRequest -> Handler (Html ())) -> Maybe IsHtmxRequest -> Handler (Html ())
withTodoId rawId continue hxReq =
  case toTodoId rawId of
    Nothing     -> MkHandler $ pure $ Left $ ServerError 404 "Not Found" (htmlBody page404) [(hContentType, "text/html; charset=utf-8")]
    Just todoId -> continue todoId hxReq

-- | Run a shared 'RouteHandler' inside servant, preserving its exact status
-- and body (including the 404-with-message from 'editTodoForm').
runRouteHandlerServant :: RouteHandler a -> Handler a
runRouteHandlerServant action = MkHandler $ do
  result <- runRouteHandler action
  pure $ case result of
    Right value                   -> Right value
    Left (RouteError status body) -> Left (routeErrorToServerError status body)

routeErrorToServerError :: Status -> LBS.ByteString -> ServerError
routeErrorToServerError status body =
  ServerError
    { errHTTPCode = statusCode status
    , errReasonPhrase = toString (decodeUtf8 (statusMessage status) :: Text)
    , errBody = body
    , errHeaders = [(hContentType, "text/plain; charset=utf-8")]
    }

notFoundApplication :: Application
notFoundApplication _req respond =
  respond notFoundResponse
