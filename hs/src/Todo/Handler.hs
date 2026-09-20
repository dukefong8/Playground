{-# LANGUAGE BlockArguments        #-}
{-# LANGUAGE GHC2024               #-}
{-# LANGUAGE NoFieldSelectors      #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
module Todo.Handler
  ( getTodosPage
  , getTodoListPartial
  , addTodo
  , toggleTodo
  , deleteTodo
  , clearCompleted
  , editTodoForm
  , updateTodo
  , generateTodos
  ) where

import Data.Text qualified as T

import Service.Hasql
import Service.Http (RouteHandler, runDbOr500, throwRouteError)
import Service.Logger
import Network.HTTP.Types (status404)
import Todo.Db
import Todo.Generate (runGenerateTodoTitles)
import Todo.Type

getTodosPage :: HasCallStack => Pool -> RouteHandler TodosView
getTodosPage pool = do
  logInfo "GET /todos page"
  items <- runDbOr500 pool getTodosSession
  logInfo $ "DB todos page todos=" <> T.show items
  pure $ TodosView items

getTodoListPartial :: HasCallStack => Pool -> RouteHandler TodoListView
getTodoListPartial pool = do
  logInfo "GET /todos/list"
  items   <- runDbOr500 pool getTodosSession
  logInfo $ "DB todos list todos=" <> T.show items
  pure $ TodoListView items Nothing False

addTodo :: HasCallStack => Pool -> AddTodoRequest -> RouteHandler TodoMutationView
addTodo pool request = do
  logInfo $ "POST /todos add title=" <> request.addTitle
  duplicateTodo <- runDbOr500 pool (getTodoByTitleSession request.addTitle)
  let isDuplicate = isJust duplicateTodo
  let addedAny = not (T.null request.addTitle) && not isDuplicate
  unless (T.null request.addTitle || isDuplicate) $
    runDbOr500 pool (addTodoSession request.addTitle)
  items <- runDbOr500 pool getTodosSession
  logInfo $ "DB add added=" <> T.show addedAny <> " duplicateTodo=" <> T.show duplicateTodo <> " todos=" <> T.show items
  pure TodoMutationView
    { todos = items
    , mutation = addMutationStatus request.addTitle isDuplicate
    , highlightedTodoId = fmap (.id) duplicateTodo
    , editingTodoId = Nothing
    , editingTitle = Nothing
    }

generateTodos :: HasCallStack => Pool -> GenerateTodosRequest -> RouteHandler TodoMutationView
generateTodos pool request = do
  let mkView todos mutation = TodoMutationView
        { todos
        , mutation
        , highlightedTodoId = Nothing
        , editingTodoId = Nothing
        , editingTitle = Nothing
        }
  existingItems <- runDbOr500 pool getTodosSession
  if T.null request.generatePrompt
    then pure $ mkView existingItems TodoGenerationEmptyPrompt
    else do
      result <- runGenerateTodoTitles request.generatePrompt
      case result of
        Left _ -> do
          logInfo "Grace todo generation failed"
          pure $ mkView existingItems TodoGenerationFailed
        Right generatedTitles -> do
          let insertable = insertableGeneratedTitles existingItems generatedTitles
              titlesToInsert = take 3 insertable
          unless (null titlesToInsert) $
            traverse_ (runDbOr500 pool . addTodoSession) titlesToInsert
          refreshedItems <- runDbOr500 pool getTodosSession
          let mutationStatus =
                if null titlesToInsert
                  then TodoGenerationNoResults
                  else TodoGenerated
          pure $ mkView refreshedItems mutationStatus

toggleTodo :: HasCallStack => Pool -> TodoId -> RouteHandler TodoMutationView
toggleTodo pool todoId = do
  logInfo $ "PATCH /todos/" <> show (unTodoId todoId) <> " toggle"
  runDbOr500 pool (toggleTodoSession todoId)
  items <- runDbOr500 pool getTodosSession
  logInfo $ "DB toggle todos=" <> T.show items
  pure $ mutationView TodoToggled items Nothing

deleteTodo :: HasCallStack => Pool -> TodoId -> RouteHandler TodoMutationView
deleteTodo pool todoId = do
  logInfo $ "DELETE /todos/" <> show (unTodoId todoId)
  runDbOr500 pool (deleteTodoSession todoId)
  items <- runDbOr500 pool getTodosSession
  logInfo $ "DB delete todos=" <> T.show items
  pure $ mutationView TodoDeleted items Nothing

clearCompleted :: HasCallStack => Pool -> RouteHandler TodoMutationView
clearCompleted pool = do
  logInfo "POST /todos/clear"
  runDbOr500 pool clearCompletedSession
  items <- runDbOr500 pool getTodosSession
  logInfo $ "DB clear todos=" <> T.show items
  pure $ mutationView TodoCleared items Nothing

editTodoForm :: HasCallStack => Pool -> TodoId -> RouteHandler TodoEditView
editTodoForm pool todoId = do
  logInfo $ "GET /todos/" <> show (unTodoId todoId) <> "/edit"
  mTodo <- runDbOr500 pool (getTodoSession todoId)
  logInfo $ "DB edit todo=" <> T.show mTodo
  case mTodo of
    Just todo -> pure $ TodoEditView todo
    Nothing   -> throwRouteError status404 "Todo not found"

updateTodo :: HasCallStack => Pool -> TodoId -> UpdateTodoRequest -> RouteHandler TodoMutationView
updateTodo pool todoId request = do
  let title' = request.updateTitle
  logInfo $ "PUT /todos/" <> show (unTodoId todoId) <> " title=" <> title'
  duplicateTodo <- runDbOr500 pool (getTodoByTitleExceptSession todoId title')
  let isDuplicate = isJust duplicateTodo
  let updated = not (T.null title') && not isDuplicate
  unless (T.null title' || isDuplicate) $
    runDbOr500 pool (updateTodoTitleSession todoId title')
  items <- runDbOr500 pool getTodosSession
  logInfo $ "DB update updated=" <> T.show updated <> " todos=" <> T.show items
  if updated
    then pure $ mutationView TodoUpdated items Nothing
    else pure (mutationView TodoUpdateDuplicate items (fmap (.id) duplicateTodo))
      { editingTodoId = Just (unTodoId todoId)
      , editingTitle = Just title'
      }
