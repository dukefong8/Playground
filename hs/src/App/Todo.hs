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
{-# LANGUAGE TypeFamilies          #-}
module App.Todo
  ( Todo(..)
  , TodoId(..)
  , TodosView(..)
  , TodoListView(..)
  , TodoEditView(..)
  , TodoMutationView(..)
  , TodoRoute(..)
  , toTodoId
  , toRowId
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
  , insertableGeneratedTitles
  , GenerateTodoTitles
  , generateTodos
  , graceGenerateTodoTitles
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Prelude hiding (id)

import Control.Exception qualified as Exception (SomeException, try)
import Database
import Grace.Input qualified (Input (Code))
import Grace.Interpret qualified as Grace (loadWith, (<~))
import Hasql.Decoders qualified as Decoders
import Htmx
import Http (RouteHandler, checkedInt64, runDbOr500, throwRouteError)
import IHP.TypedSql.Hasql (sqlExecTypedSession, sqlQueryTypedSession, typedSql)
import IHP.TypedSql.Id (Id' (..), PrimaryKey)
import IHP.TypedSql.Row (TypedSqlRow (..))
import Logger
import Network.HTTP.Types (status404)
import Web.FormUrlEncoded

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
  | TodoFilterScriptAction
  deriving (Eq, Show)

data Todo = Todo { id :: Int64, title :: Text, completed :: Bool }
  deriving (Eq, Show)

-- NOTE: positional coupling — decoder order must match the SELECT column
-- order of every full-table todos query below (id, title, completed).
-- Reorder columns in either place and this breaks at runtime, not compile time.
instance TypedSqlRow Todo where
  typedSqlRowDecoder =
    Todo
      <$> Decoders.column (Decoders.nonNullable Decoders.int8)
      <*> Decoders.column (Decoders.nonNullable Decoders.text)
      <*> Decoders.column (Decoders.nonNullable Decoders.bool)

type instance PrimaryKey "todos" = Int64

-- | Todo identity parsed once at the HTTP boundary. Handlers and sessions
-- take TodoId; conversion to the row-level Id' happens only at SQL sites
-- via toRowId, and unwrapping to Int64 only where views/tests need raw ids.
newtype TodoId = TodoId Int64
  deriving (Eq, Show)

unTodoId :: TodoId -> Int64
unTodoId (TodoId intId) = intId

toTodoId :: Integer -> Maybe TodoId
toTodoId = fmap TodoId . checkedInt64

toRowId :: TodoId -> Id' "todos"
toRowId (TodoId intId) = Id intId

data AddTodoRequest = AddTodoRequest
  { addTitle :: Text
  } deriving (Eq, Show)

instance FromForm AddTodoRequest where
  fromForm form =
    AddTodoRequest . normalizeTitle <$> parseUnique "title" form

data GenerateTodosRequest = GenerateTodosRequest
  { generatePrompt :: Text
  } deriving (Eq, Show)

instance FromForm GenerateTodosRequest where
  fromForm form =
    GenerateTodosRequest . normalizeTitle <$> parseUnique "title" form

data UpdateTodoRequest = UpdateTodoRequest
  { updateTitle :: Text
  } deriving (Eq, Show)

instance FromForm UpdateTodoRequest where
  fromForm form = do
    editTitle <- parseMaybe "edit-title" form
    title <- parseMaybe "title" form
    pure $ UpdateTodoRequest
      (normalizeTitle (fromMaybe "" (editTitle <|> title)))

data TodoMutationStatus
  = TodoCreated
  | TodoDuplicate
  | TodoEmptyTitle
  | TodoToggled
  | TodoDeleted
  | TodoCleared
  | TodoUpdated
  | TodoUpdateDuplicate
  | TodoGenerated
  | TodoGenerationEmptyPrompt
  | TodoGenerationNoResults
  | TodoGenerationFailed
  deriving (Eq, Show)

newtype TodosView = TodosView
  { todos :: [Todo]
  } deriving (Eq, Show)

renderTodosViewHtml :: TodosView -> LBS.ByteString
renderTodosViewHtml todosView = renderBS $ todoPage todosView.todos

data TodoListView = TodoListView
  { todos             :: [Todo]
  , highlightedTodoId :: Maybe Int64
  , outOfBand         :: Bool
  } deriving (Eq, Show)

renderTodoListViewHtml :: TodoListView -> LBS.ByteString
renderTodoListViewHtml listView =
  renderBS $
    todoListSectionHighlightedOob
      listView.todos
      listView.highlightedTodoId
      listView.outOfBand

newtype TodoEditView = TodoEditView Todo
  deriving (Eq, Show)

renderTodoEditViewHtml :: TodoEditView -> LBS.ByteString
renderTodoEditViewHtml (TodoEditView todo) = renderBS $ todoEditForm todo

data TodoMutationView = TodoMutationView
  { todos             :: [Todo]
  , mutation          :: TodoMutationStatus
  , highlightedTodoId :: Maybe Int64
  , editingTodoId     :: Maybe Int64
  , editingTitle      :: Maybe Text
  } deriving (Eq, Show)

renderTodoMutationViewHtml :: TodoMutationView -> LBS.ByteString
renderTodoMutationViewHtml mutationResult = renderBS case mutationResult.mutation of
  TodoCreated               -> addResponseHtml
  TodoDuplicate             -> addResponseHtml
  TodoEmptyTitle            -> addResponseHtml
  TodoUpdated               -> todoListHtml >> focusTodoInputScript
  TodoUpdateDuplicate       -> todoListHtml >> maybe mempty focusEditInputScript mutationResult.editingTodoId
  TodoGenerated             -> generationResponseHtml Nothing
  TodoGenerationEmptyPrompt -> generationResponseHtml (Just "Enter something before feeling lucky.")
  TodoGenerationNoResults   -> generationResponseHtml (Just "Grace did not return any new todo titles.")
  TodoGenerationFailed      -> generationResponseHtml (Just "Could not generate todos; check DEEPSEEK_API_KEY and try again.")
  _                         -> todoListHtml
  where
    addResponseHtml = do
      todoAddForm Nothing
      todoListSectionHighlightedOob mutationResult.todos mutationResult.highlightedTodoId True
    generationResponseHtml message = do
      todoAddForm message
      todoListSectionHighlightedOob mutationResult.todos Nothing True
    todoListHtml =
      todoListSectionWithOptions
        mutationResult.todos
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

getTodosSession :: Session [Todo]
getTodosSession = sqlQueryTypedSession [typedSql|
  select id, title, completed from todos order by id
|]

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

type GenerateTodoTitles = Text -> RouteHandler (Either Text [Text])

generateTodos :: HasCallStack => Pool -> GenerateTodoTitles -> GenerateTodosRequest -> RouteHandler TodoMutationView
generateTodos pool generate request = do
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
      result <- generate request.generatePrompt
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

insertableGeneratedTitles :: [Todo] -> [Text] -> [Text]
insertableGeneratedTitles existingItems =
  take 3
    . filter (not . T.null)
    . filter
        ( \title ->
            let key = normalizeTitleKey title
             in not $ any ((== key) . normalizeTitleKey . (.title)) existingItems
        )
    . fmap normalizeTitle
    . uniqueVia normalizeTitleKey
  where
    uniqueVia :: Ord b => (a -> b) -> [a] -> [a]
    uniqueVia f = go []
      where
        go _ [] = []
        go seen (x : xs)
          | f x `elem` seen = go seen xs
          | otherwise = x : go (f x : seen) xs

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

addMutationStatus :: Text -> Bool -> TodoMutationStatus
addMutationStatus titleExists isDuplicate
  | T.null titleExists = TodoEmptyTitle
  | isDuplicate = TodoDuplicate
  | otherwise = TodoCreated

mutationView :: TodoMutationStatus -> [Todo] -> Maybe Int64 -> TodoMutationView
mutationView status items highlightedTodoId' =
  TodoMutationView
    { todos = items
    , mutation = status
    , highlightedTodoId = highlightedTodoId'
    , editingTodoId = Nothing
    , editingTitle = Nothing
    }


addTodoSession :: Text -> Session ()
addTodoSession title' = void $ sqlExecTypedSession [typedSql|
  insert into todos (title) values (${title'})
|]

getTodoByTitleSession :: Text -> Session (Maybe Todo)
getTodoByTitleSession title' = sqlQueryTypedSession [typedSql|
  select id, title, completed
  from todos
  where lower(btrim(title)) = lower(btrim(${title'}))
  order by id
  limit 1
|]

getTodoByTitleExceptSession :: TodoId -> Text -> Session (Maybe Todo)
getTodoByTitleExceptSession todoId title' = sqlQueryTypedSession [typedSql|
  select id, title, completed
  from todos
  where id <> ${unTodoId todoId}
    and lower(btrim(title)) = lower(btrim(${title'}))
  order by id
  limit 1
|]

toggleTodoSession :: TodoId -> Session ()
toggleTodoSession todoId = void $ sqlExecTypedSession [typedSql|
  update todos set completed = not completed where id = ${toRowId todoId}
|]

deleteTodoSession :: TodoId -> Session ()
deleteTodoSession todoId = void $ sqlExecTypedSession [typedSql|
  delete from todos where id = ${toRowId todoId}
|]

clearCompletedSession :: Session ()
clearCompletedSession = void $ sqlExecTypedSession [typedSql|
  delete from todos where completed = true
|]

getTodoSession :: TodoId -> Session (Maybe Todo)
getTodoSession todoId = sqlQueryTypedSession [typedSql|
  select id, title, completed from todos where id = ${toRowId todoId}
|]

updateTodoTitleSession :: TodoId -> Text -> Session ()
updateTodoTitleSession todoId title' = void $ sqlExecTypedSession [typedSql|
  update todos set title = ${title'} where id = ${toRowId todoId}
|]

todoPage :: [Todo] -> Html ()
todoPage items =
  pageShell todoHead [hsx|
    <section
      class="todoapp"
      data-filter-mode="all"
      hx-on:input="window.todoFilterApply()"
      hx-on:click="const a = event.target.closest('a[data-filter]'); if (a) { event.preventDefault(); window.todoFilterSet(a.dataset.filter); }"
      hx-on::finally:swap="window.todoFilterApply()"
    >
      <header class="header">
        <h1>todos</h1>
        {todoAddForm Nothing}
      </header>
      {todoListSection items}
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

    .input-button-row {
      display: flex;
      width: 100%;
    }

    .input-button-row .new-todo {
      flex: 4;
    }

    .input-button-row .lucky-todo {
      flex: 1;
      font-size: 16px;
      cursor: pointer;
      border: none;
      border-left: 1px solid #e6e6e6;
      background: #f5f5f5;
      color: #777;
      outline: none;
    }

    .input-button-row .lucky-todo:hover {
      background: #e8e8e8;
    }

    .input-button-row .lucky-todo:active {
      background: #ddd;
    }

    .generation-feedback {
      padding-left: 60px;
      font-size: 14px;
      color: #999;
    }

    .todo-list li[hidden] {
      display: none;
    }
  </style>
  <script src="/todo-filter.cljs" type="application/x-scittle"></script>
|]

todoAddForm :: Maybe Text -> Html ()
todoAddForm message = [hsx|
  <form
    id="add-form"
    hx-post="/todos"
    hx-target="#add-form"
    hx-swap="outerHTML"
  >
    <div class="input-button-row">
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
      >
      <button
        type="button"
        class="lucky-todo"
        hx-post="/todos/generate"
        hx-include="#add-form"
        hx-target="#add-form"
        hx-swap="outerHTML"
      >
        I feel lucky today
      </button>
    </div>
    <div class="generation-message">
      {generationMessage}
    </div>
  </form>
|]
  where
    generationMessage = case message of
      Nothing  -> mempty
      Just msg -> [hsx|<span class="generation-feedback">{msg}</span>|]

todoEditForm :: Todo -> Html ()
todoEditForm todo = todoEditFormWithTitle todo todo.title

todoEditFormWithTitle :: Todo -> Text -> Html ()
todoEditFormWithTitle todo title' = [hsx|
  <li id={"todo-" <> show todo.id :: Text} class="editing">
    <form
      hx-put={"/todos/" <> show todo.id :: Text}
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

filterLink :: Text -> Text -> Bool -> Html ()
filterLink name label selected = [hsx|
  <li>
    <a
      href="#"
      data-filter={name}
      class={classes}
    >
      {label}
    </a>
  </li>
|]
  where
    classes :: Text
    classes
      | selected  = "selected"
      | otherwise = ""

todoListSection :: [Todo] -> Html ()
todoListSection items =
  todoListSectionWithOptions items Nothing False Nothing Nothing

todoListSectionHighlighted :: [Todo] -> Maybe Int64 -> Html ()
todoListSectionHighlighted items highlightedTodoId =
  todoListSectionWithOptions items highlightedTodoId False Nothing Nothing

todoListSectionHighlightedOob :: [Todo] -> Maybe Int64 -> Bool -> Html ()
todoListSectionHighlightedOob items highlightedTodoId oob =
  todoListSectionWithOptions items highlightedTodoId oob Nothing Nothing

todoListSectionWithOptions :: [Todo] -> Maybe Int64 -> Bool -> Maybe Int64 -> Maybe Text -> Html ()
todoListSectionWithOptions items highlightedTodoId oob editingTodoId editingTitle =
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
        <section class="main">
          {toggleAll}
          <label for="toggle-all">Mark all as complete</label>
          <ul class="todo-list">
            {mapM_ todoRow items}
          </ul>
        </section>
        <footer class="footer">
          <span class="todo-count"><strong>{activeCountText}</strong> {todoCountLabel activeCount}</span>
          <ul class="filters">
            {filterLink "all" "All" True}
            {filterLink "active" "Active" False}
            {filterLink "completed" "Completed" False}
          </ul>
          {clearButton}
        </footer>
      </div>
    |]
    -- Counts cover all items; every item renders and the scittle
    -- live filter hides non-matching rows client-side.
    (activeCount, completedCount) =
      foldl'
        ( \(active, completed) todo ->
            ( if todo.completed then active else active + 1
            , if todo.completed then completed + 1 else completed
            )
        )
        (0, 0)
        items
    activeCountText :: Text
    activeCountText = show activeCount
    allCompleted = not (null items) && all (.completed) items
    toggleAll :: Html ()
    toggleAll
      | allCompleted = [hsx|
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
            hx-target="#todo-list"
            hx-swap={listSwap}
          >
            Clear completed
          </button>
        |]
      | otherwise = mempty

todoCountLabel :: Int -> Text
todoCountLabel n = (if n == 1 then "item" else "items") <> " left"

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
            hx-target="#todo-list"
            hx-swap={listSwap}
          >
        |]
      | otherwise = [hsx|
          <input
            class="toggle"
            type="checkbox"
            hx-patch={patchPath}
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
