{-# LANGUAGE BlockArguments        #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DerivingVia           #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GHC2024               #-}
{-# LANGUAGE NoFieldSelectors      #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PatternSynonyms       #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE TypeApplications      #-}
module App.Todo
  ( Todo(..)
  , TodosView(..)
  , TodoListView(..)
  , TodoEditView(..)
  , TodoMutationView(..)
  , getTodosPage
  , getTodoListPartial
  , addTodo
  , toggleTodo
  , deleteTodo
  , clearCompleted
  , editTodoForm
  , updateTodo
  , renderTodosViewHtml
  , renderTodoListViewHtml
  , renderTodoEditViewHtml
  , renderTodoMutationViewHtml
  , getTodosSession
  , addTodoSession
  , toggleTodoSession
  , clearCompletedSession
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Data.Vector qualified as V
import Prelude hiding (id)

import Colog (LoggerT, Message, cmap, fmtMessage, logInfo, logTextStdout, usingLoggerT)
import Database
import Hasql.TH
import Htmx
import Http (RouteHandler, runDbOr500, throwRouteError)
import Network.HTTP.Types (status404)
import Web.FormUrlEncoded

data Todo = Todo { id :: Int64, title :: Text, completed :: Bool }
  deriving (Eq, Show)

data TodoListState = TodoListState
  { stateFilter :: Maybe Text
  , stateTitle  :: Maybe Text
  } deriving (Eq, Show)

instance FromForm TodoListState where
  fromForm form =
    TodoListState
      <$> parseMaybe "filter" form
      <*> parseMaybe "title" form

data AddTodoRequest = AddTodoRequest
  { addTitle :: Text
  , addState :: TodoListState
  } deriving (Eq, Show)

instance FromForm AddTodoRequest where
  fromForm form =
    AddTodoRequest
      <$> parseUnique "title" form
      <*> fromForm form

data UpdateTodoRequest = UpdateTodoRequest
  { updateTitle :: Text
  , updateState :: TodoListState
  } deriving (Eq, Show)

instance FromForm UpdateTodoRequest where
  fromForm form = do
    editTitle <- parseMaybe "edit-title" form
    title <- parseMaybe "title" form
    UpdateTodoRequest
      (fromMaybe "" (editTitle <|> title))
      <$> fromForm form

data TodoMutationStatus
  = TodoCreated
  | TodoDuplicate
  | TodoEmptyTitle
  | TodoToggled
  | TodoDeleted
  | TodoCleared
  | TodoUpdated
  | TodoUpdateDuplicate
  deriving (Eq, Show)

data TodosView = TodosView
  { todos       :: [Todo]
  , filterBy    :: Text
  , searchTitle :: Text
  } deriving (Eq, Show)

renderTodosViewHtml :: TodosView -> LBS.ByteString
renderTodosViewHtml todosView = renderBS $ todoPage todosView.todos todosView.filterBy

data TodoListView = TodoListView
  { todos             :: [Todo]
  , filterBy          :: Text
  , searchTitle       :: Text
  , highlightedTodoId :: Maybe Int64
  , outOfBand         :: Bool
  } deriving (Eq, Show)

renderTodoListViewHtml :: TodoListView -> LBS.ByteString
renderTodoListViewHtml listView =
  renderBS $
    todoListSectionHighlightedOob
      listView.todos
      listView.searchTitle
      listView.filterBy
      listView.highlightedTodoId
      listView.outOfBand

newtype TodoEditView = TodoEditView Todo
  deriving (Eq, Show)

renderTodoEditViewHtml :: TodoEditView -> LBS.ByteString
renderTodoEditViewHtml (TodoEditView todo) = renderBS $ todoEditForm todo

data TodoMutationView = TodoMutationView
  { todos             :: [Todo]
  , filterBy          :: Text
  , searchTitle       :: Text
  , mutation          :: TodoMutationStatus
  , highlightedTodoId :: Maybe Int64
  , editingTodoId     :: Maybe Int64
  , editingTitle      :: Maybe Text
  } deriving (Eq, Show)

renderTodoMutationViewHtml :: TodoMutationView -> LBS.ByteString
renderTodoMutationViewHtml mutationResult = renderBS case mutationResult.mutation of
  TodoCreated         -> addResponseHtml
  TodoDuplicate       -> addResponseHtml
  TodoEmptyTitle      -> addResponseHtml
  TodoUpdated         -> todoListHtml >> focusTodoInputScript
  TodoUpdateDuplicate -> todoListHtml >> maybe mempty focusEditInputScript mutationResult.editingTodoId
  _                   -> todoListHtml
  where
    addResponseHtml = do
      todoAddForm
      todoListSectionHighlightedOob mutationResult.todos "" mutationResult.filterBy mutationResult.highlightedTodoId True
    todoListHtml =
      todoListSectionWithOptions
        mutationResult.todos
        mutationResult.searchTitle
        mutationResult.filterBy
        mutationResult.highlightedTodoId
        False
        mutationResult.editingTodoId
        mutationResult.editingTitle


normalizeTitle :: Text -> Text
normalizeTitle = T.strip

normalizeTitleKey :: Text -> Text
normalizeTitleKey = T.toCaseFold . normalizeTitle

listSwap :: Text
listSwap = "outerMorph"

searchInputInclude :: Text
searchInputInclude = "#todo-input:not(:invalid)"

listStateInclude :: Text
listStateInclude = "#todo-list-form, " <> searchInputInclude

addFormFilterInclude :: Text
addFormFilterInclude = "#todo-list-form input[name='filter']"

logger :: MonadIO m => LoggerT Message m a -> m a
logger = usingLoggerT $ cmap fmtMessage logTextStdout

logInfoH :: HasCallStack => Text -> RouteHandler ()
logInfoH msg =
  withFrozenCallStack $ logger $ logInfo msg

getTodosSession :: Session [Todo]
getTodosSession = do
  V.toList . V.map (\(id', title', completed') -> Todo id' title' completed') <$> statement ()
    [vectorStatement|
      select id :: int8, title :: text, completed :: bool from todos order by id
    |]

getTodosPage :: HasCallStack => Pool -> Maybe Text -> Maybe Text -> RouteHandler TodosView
getTodosPage pool filter_ search_ = do
  logInfoH $ "GET /todos page filter=" <> filterText filter_ <> " search=" <> searchText search_
  items <- runDbOr500 pool getTodosSession
  logInfoH $ "DB todos page todos=" <> T.show items
  pure $ TodosView items (filterText filter_) (searchText search_)

getTodoListPartial :: HasCallStack => Pool -> Maybe Text -> Maybe Text -> RouteHandler TodoListView
getTodoListPartial pool filter_ search_ = do
  logInfoH $ "GET /todos/list filter=" <> filterText filter_ <> " search=" <> searchText search_
  items   <- runDbOr500 pool getTodosSession
  logInfoH $ "DB todos list todos=" <> T.show items
  pure $ TodoListView items (filterText filter_) (searchText search_) Nothing False

addTodo :: HasCallStack => Pool -> AddTodoRequest -> RouteHandler TodoMutationView
addTodo pool request = do
  let normalizedTitle = normalizeTitle request.addTitle
  logInfoH $ "POST /todos add title=" <> normalizedTitle
  isDuplicate <- runDbOr500 pool (todoTitleExistsSession normalizedTitle)
  duplicateTodo <-
    if isDuplicate
      then runDbOr500 pool (getTodoByTitleSession normalizedTitle)
      else pure Nothing
  let addedAny = not (T.null normalizedTitle) && not isDuplicate
  unless (T.null normalizedTitle || isDuplicate) $
    runDbOr500 pool (addTodoSession normalizedTitle)
  items <- runDbOr500 pool getTodosSession
  logInfoH $ "DB add added=" <> T.show addedAny <> " duplicateTodo=" <> T.show duplicateTodo <> " todos=" <> T.show items
  pure TodoMutationView
    { todos = items
    , filterBy = stateFilterText request.addState
    , searchTitle = ""
    , mutation = addMutationStatus normalizedTitle isDuplicate
    , highlightedTodoId = fmap (.id) duplicateTodo
    , editingTodoId = Nothing
    , editingTitle = Nothing
    }

toggleTodo :: HasCallStack => Pool -> Int64 -> TodoListState -> RouteHandler TodoMutationView
toggleTodo pool todoId listState = do
  logInfoH $ "PATCH /todos/" <> show todoId <> " toggle"
  runDbOr500 pool (toggleTodoSession todoId)
  items <- runDbOr500 pool getTodosSession
  logInfoH $ "DB toggle todos=" <> T.show items
  pure $ mutationView TodoToggled listState items Nothing

deleteTodo :: HasCallStack => Pool -> Int64 -> Maybe Text -> RouteHandler TodoMutationView
deleteTodo pool todoId mFilter = do
  logInfoH $ "DELETE /todos/" <> show todoId
  runDbOr500 pool (deleteTodoSession todoId)
  items <- runDbOr500 pool getTodosSession
  logInfoH $ "DB delete todos=" <> T.show items
  pure $ mutationView TodoDeleted (TodoListState mFilter Nothing) items Nothing

clearCompleted :: HasCallStack => Pool -> TodoListState -> RouteHandler TodoMutationView
clearCompleted pool listState = do
  logInfoH "POST /todos/clear"
  runDbOr500 pool clearCompletedSession
  items <- runDbOr500 pool getTodosSession
  logInfoH $ "DB clear todos=" <> T.show items
  pure $ mutationView TodoCleared listState items Nothing

editTodoForm :: HasCallStack => Pool -> Int64 -> RouteHandler TodoEditView
editTodoForm pool todoId = do
  logInfoH $ "GET /todos/" <> show todoId <> "/edit"
  mTodo <- runDbOr500 pool (getTodoSession todoId)
  logInfoH $ "DB edit todo=" <> T.show mTodo
  case mTodo of
    Just todo -> pure $ TodoEditView todo
    Nothing   -> throwRouteError status404 "Todo not found"

updateTodo :: HasCallStack => Pool -> Int64 -> UpdateTodoRequest -> RouteHandler TodoMutationView
updateTodo pool todoId request = do
  let title' = request.updateTitle
  let normalizedTitle = normalizeTitle title'
  logInfoH $ "PUT /todos/" <> show todoId <> " title=" <> normalizedTitle
  isDuplicate <- runDbOr500 pool (todoTitleExistsExceptSession todoId normalizedTitle)
  duplicateTodo <-
    if isDuplicate
      then runDbOr500 pool (getTodoByTitleExceptSession todoId normalizedTitle)
      else pure Nothing
  let updated = not (T.null normalizedTitle) && not isDuplicate
  unless (T.null normalizedTitle || isDuplicate) $
    runDbOr500 pool (updateTodoTitleSession todoId normalizedTitle)
  items <- runDbOr500 pool getTodosSession
  logInfoH $ "DB update updated=" <> T.show updated <> " todos=" <> T.show items
  if updated
    then pure $ mutationView TodoUpdated request.updateState items Nothing
    else pure (mutationView TodoUpdateDuplicate request.updateState items (fmap (.id) duplicateTodo))
      { editingTodoId = Just todoId
      , editingTitle = Just title'
      }

filterText :: Maybe Text -> Text
filterText = fromMaybe "all"

searchText :: Maybe Text -> Text
searchText = fromMaybe ""

stateFilterText :: TodoListState -> Text
stateFilterText = filterText . (.stateFilter)

stateSearchText :: TodoListState -> Text
stateSearchText = searchText . (.stateTitle)

addMutationStatus :: Text -> Bool -> TodoMutationStatus
addMutationStatus titleExists isDuplicate
  | T.null titleExists = TodoEmptyTitle
  | isDuplicate = TodoDuplicate
  | otherwise = TodoCreated

mutationView :: TodoMutationStatus -> TodoListState -> [Todo] -> Maybe Int64 -> TodoMutationView
mutationView status listState items highlightedTodoId' =
  TodoMutationView
    { todos = items
    , filterBy = stateFilterText listState
    , searchTitle = stateSearchText listState
    , mutation = status
    , highlightedTodoId = highlightedTodoId'
    , editingTodoId = Nothing
    , editingTitle = Nothing
    }


addTodoSession :: Text -> Session ()
addTodoSession title' = statement title'
  [resultlessStatement| insert into todos (title) values ($1 :: text) |]

todoTitleExistsSession :: Text -> Session Bool
todoTitleExistsSession title' = do
  res <- statement title'
    [maybeStatement|
      select 1 :: int4
      from todos
      where lower(btrim(title)) = lower(btrim($1 :: text))
      limit 1
    |]
  pure $ isJust res

getTodoByTitleSession :: Text -> Session (Maybe Todo)
getTodoByTitleSession title' = do
  fmap (\(id', title'', completed') -> Todo id' title'' completed') <$> statement title'
    [maybeStatement|
      select id :: int8, title :: text, completed :: bool
      from todos
      where lower(btrim(title)) = lower(btrim($1 :: text))
      order by id
      limit 1
    |]

getTodoByTitleExceptSession :: Int64 -> Text -> Session (Maybe Todo)
getTodoByTitleExceptSession id' title' = do
  fmap (\(id'', title'', completed') -> Todo id'' title'' completed') <$> statement (id', title')
    [maybeStatement|
      select id :: int8, title :: text, completed :: bool
      from todos
      where id <> $1 :: int8
        and lower(btrim(title)) = lower(btrim($2 :: text))
      order by id
      limit 1
    |]

todoTitleExistsExceptSession :: Int64 -> Text -> Session Bool
todoTitleExistsExceptSession id' title' = do
  res <- statement (id', title')
    [maybeStatement|
      select 1 :: int4
      from todos
      where id <> $1 :: int8
        and lower(btrim(title)) = lower(btrim($2 :: text))
      limit 1
    |]
  pure $ isJust res

toggleTodoSession :: Int64 -> Session ()
toggleTodoSession id' = statement id'
  [resultlessStatement| update todos set completed = not completed where id = $1 :: int8 |]

deleteTodoSession :: Int64 -> Session ()
deleteTodoSession id' = statement id'
  [resultlessStatement| delete from todos where id = $1 :: int8 |]

clearCompletedSession :: Session ()
clearCompletedSession = statement ()
  [resultlessStatement| delete from todos where completed = true |]

getTodoSession :: Int64 -> Session (Maybe Todo)
getTodoSession id' = do
  fmap (\(id'', title', completed') -> Todo id'' title' completed') <$> statement id'
    [maybeStatement|
      select id :: int8, title :: text, completed :: bool from todos where id = $1 :: int8
    |]

updateTodoTitleSession :: Int64 -> Text -> Session ()
updateTodoTitleSession id' title' = statement (title', id')
  [resultlessStatement| update todos set title = $1 :: text where id = $2 :: int8 |]

todoPage :: [Todo] -> Text -> Html ()
todoPage items filterBy =
  pageShell todoHead [hsx|
    <section class="todoapp">
      <header class="header">
        <h1>todos</h1>
        {todoAddForm}
      </header>
      {todoListSection items "" filterBy}
      <footer class="info">
        <p>Double-click to edit, Enter to add</p>
      </footer>
    </section>
  |]

todoHead :: Html ()
todoHead = [hsx|
  <title>Todo Servant</title>
  <link href="https://unpkg.com/todomvc-app-css@2.4.1/index.css" rel="stylesheet">
  <style>
    @keyframes duplicate-flash {
      0% {
        background: rgba(255, 208, 0, 0.45);
      }

      100% {
        background: transparent;
      }
    }

    .todo-list li.duplicate-flash {
      animation: duplicate-flash 0.9s ease;
    }
  </style>
|]

todoAddForm :: Html ()
todoAddForm = [hsx|
  <form
    id="add-form"
    hx-post="/todos"
    hx-target="#add-form"
    hx-swap="outerHTML"
    hx-include={addFormFilterInclude}
  >
    <input
      id="todo-input"
      class="new-todo"
      type="text"
      aria-label="New todo"
      name="title"
      placeholder="What needs to be done?"
      autocomplete="off"
      required
      autofocus
      hx-get="/todos/list"
      hx-trigger="input changed delay:500ms"
      hx-include={addFormFilterInclude}
      hx-target="#todo-list"
      hx-swap={listSwap}
      hx-sync="closest form:abort"
    >
  </form>
|]

todoEditForm :: Todo -> Html ()
todoEditForm todo = todoEditFormWithTitle todo todo.title

todoEditFormWithTitle :: Todo -> Text -> Html ()
todoEditFormWithTitle todo title' = [hsx|
  <li id={"todo-" <> show todo.id :: Text} class="editing">
    <form
      hx-put={"/todos/" <> show todo.id :: Text}
      hx-include={listStateInclude}
      hx-target="#todo-list"
      hx-swap={listSwap}
    >
      <input
        class="edit"
        type="text"
        id={"todo-edit-" <> show todo.id :: Text}
        name="edit-title"
        value={title'}
        autofocus
        required
      >
    </form>
  </li>
|]

filterLink :: Text -> Text -> Text -> Html ()
filterLink filterName label currentFilter = [hsx|
  <li>{anchor}</li>
|]
  where
    href :: Text
    href = "/todos/list?filter=" <> filterName
    anchor :: Html ()
    anchor =
      [hsx|
        <a
          href="#"
          class={classes}
          hx-get={href}
          hx-include={searchInputInclude}
          hx-target="#todo-list"
          hx-swap={listSwap}
        >
          {label}
        </a>
      |]
      where
        classes :: Text
        classes
          | filterName == currentFilter = "selected"
          | otherwise                   = ""

todoListSection :: [Todo] -> Text -> Text -> Html ()
todoListSection items searchQ filterBy =
  todoListSectionWithOptions items searchQ filterBy Nothing False Nothing Nothing

todoListSectionHighlighted :: [Todo] -> Text -> Text -> Maybe Int64 -> Html ()
todoListSectionHighlighted items searchQ filterBy highlightedTodoId =
  todoListSectionWithOptions items searchQ filterBy highlightedTodoId False Nothing Nothing

todoListSectionHighlightedOob :: [Todo] -> Text -> Text -> Maybe Int64 -> Bool -> Html ()
todoListSectionHighlightedOob items searchQ filterBy highlightedTodoId oob =
  todoListSectionWithOptions items searchQ filterBy highlightedTodoId oob Nothing Nothing

todoListSectionWithOptions :: [Todo] -> Text -> Text -> Maybe Int64 -> Bool -> Maybe Int64 -> Maybe Text -> Html ()
todoListSectionWithOptions items searchQ filterBy highlightedTodoId oob editingTodoId editingTitle =
  if oob
    then [hsx|
      <div id="todo-list" hx-swap-oob={listSwap}>
        {todoListForm}
      </div>
    |]
    else [hsx|
      <div id="todo-list">
        {todoListForm}
      </div>
    |]
  where
    todoListForm = [hsx|
      <div id="todo-list-form">
        <input type="hidden" name="filter" value={filterBy}>
        <section class="main">
          {toggleAll}
          <label for="toggle-all">Mark all as complete</label>
          <ul class="todo-list">
            {mapM_ todoRow matched}
          </ul>
        </section>
        <footer class="footer">
          <span class="todo-count"><strong>{activeCountText}</strong> {todoCountLabel activeCount}</span>
          <ul class="filters">
            {filterLink "all" "All" filterBy}
            {filterLink "active" "Active" filterBy}
            {filterLink "completed" "Completed" filterBy}
          </ul>
          {clearButton}
        </footer>
      </div>
    |]
    searched = filter (todoMatchesSearch searchQ) items
    matched = case filterBy of
      "active"    -> filter (not . (.completed)) searched
      "completed" -> filter (.completed) searched
      _           -> searched
    activeCount = length $ filter (not . (.completed)) items
    activeCountText :: Text
    activeCountText = show activeCount
    completedCount = length $ filter (.completed) items
    allMatchedCompleted = not (null matched) && all (.completed) matched
    toggleAll :: Html ()
    toggleAll
      | allMatchedCompleted = [hsx|
          <input
            id="toggle-all"
            class="toggle-all"
            type="checkbox"
            checked
          >
        |]
      | otherwise = [hsx|
          <input
            id="toggle-all"
            class="toggle-all"
            type="checkbox"
          >
        |]
    todoRow :: Todo -> Html ()
    todoRow todo
      | Just todo.id == editingTodoId = todoEditFormWithTitle todo (fromMaybe todo.title editingTitle)
      | otherwise = todoItemHighlighted highlightedTodoId todo
    clearButton :: Html ()
    clearButton
      | completedCount > 0 = [hsx|
          <button
            class="clear-completed"
            hx-post="/todos/clear"
            hx-include={listStateInclude}
            hx-target="#todo-list"
            hx-swap={listSwap}
          >
            Clear completed
          </button>
        |]
      | otherwise = mempty

todoCountLabel :: Int -> Text
todoCountLabel n = (if n == 1 then "item" else "items") <> " left"

todoMatchesSearch :: Text -> Todo -> Bool
todoMatchesSearch searchQ todo =
  maybe True (`T.isInfixOf` normalizeTitleKey todo.title) (normalizeSearch searchQ)

normalizeSearch :: Text -> Maybe Text
normalizeSearch = nonEmptyText . normalizeTitleKey . T.replace "+" " "

nonEmptyText :: Text -> Maybe Text
nonEmptyText text
  | T.null text = Nothing
  | otherwise = Just text

todoItem :: Todo -> Html ()
todoItem = todoItemHighlighted Nothing

todoItemHighlighted :: Maybe Int64 -> Todo -> Html ()
todoItemHighlighted highlightedTodoId todo = [hsx|
  <li
    id={"todo-" <> show todo.id :: Text}
    class={classes}
  >
    <div class="view">
      {toggle}
      <label
        hx-get={editPath}
        hx-trigger="dblclick"
        hx-target={itemTarget}
        hx-swap={listSwap}
      >
        {todo.title}
      </label>
      <button
        class="destroy"
        hx-delete={deletePath}
        hx-include={listStateInclude}
        hx-target="#todo-list"
        hx-swap={listSwap}
      ></button>
    </div>
  </li>
|]
  where
    patchPath  = "/todos/" <> show todo.id :: Text
    deletePath = "/todos/" <> show todo.id :: Text
    editPath   = "/todos/" <> show todo.id <> "/edit" :: Text
    itemTarget = "#todo-" <> show todo.id :: Text
    classes :: Text
    classes = unwords $ completedClass <> highlightClass
    completedClass
      | todo.completed = ["completed"]
      | otherwise = []
    highlightClass
      | Just todo.id == highlightedTodoId = ["duplicate-flash"]
      | otherwise = []
    toggle :: Html ()
    toggle
      | todo.completed = [hsx|
          <input
            class="toggle"
            type="checkbox"
            checked
            hx-patch={patchPath}
            hx-include={listStateInclude}
            hx-target="#todo-list"
            hx-swap={listSwap}
          >
        |]
      | otherwise = [hsx|
          <input
            class="toggle"
            type="checkbox"
            hx-patch={patchPath}
            hx-include={listStateInclude}
            hx-target="#todo-list"
            hx-swap={listSwap}
          >
        |]

focusTodoInputScript :: Html ()
focusTodoInputScript =
  [hsx|
    <script>
      setTimeout(function(){document.getElementById('todo-input')?.focus()},0)
    </script>
  |]

focusEditInputScript :: Int64 -> Html ()
focusEditInputScript todoId =
  toHtmlRaw ("<script>setTimeout(function(){document.querySelector('#todo-" <> show todoId <> " .edit')?.focus()},0)</script>" :: Text)
