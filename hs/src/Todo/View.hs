{-# LANGUAGE BlockArguments      #-}
{-# LANGUAGE GHC2024           #-}
{-# LANGUAGE NoFieldSelectors  #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
module Todo.View
  ( TodoLinks(..)
  , todoLinks
  , renderTodosViewHtml
  , renderTodoListViewHtml
  , renderTodoEditViewHtml
  , renderTodoMutationViewHtml
  , todosViewHtml
  , todoListViewHtml
  , todoEditViewHtml
  , todoMutationViewHtml
  , todoPage
  , todoAddForm
  , todoEditForm
  , todoListSection
  , todoListSectionHighlighted
  , todoListSectionHighlightedOob
  , todoItem
  , listSwap
  ) where

import Data.ByteString.Lazy qualified as LBS
import Prelude hiding (id)

import Htmx
import Todo.Filter (filterScriptFile)
import Todo.Type

-- | URL construction for todo views, parameterized over the mount prefix so
-- the ihp-router (/app) and servant (/servant) stacks share every view.
data TodoLinks = TodoLinks
  { linkTodos    :: Text
  , linkGenerate :: Text
  , linkClear    :: Text
  , linkItem     :: Int64 -> Text
  , linkEdit     :: Int64 -> Text
  }

todoLinks :: Text -> TodoLinks
todoLinks prefix = TodoLinks
  { linkTodos = prefix <> "/todos"
  , linkGenerate = prefix <> "/todos/generate"
  , linkClear = prefix <> "/todos/clear"
  , linkItem = \todoId -> prefix <> "/todos/" <> show todoId
  , linkEdit = \todoId -> prefix <> "/todos/" <> show todoId <> "/edit"
  }

renderTodosViewHtml :: TodoLinks -> TodosView -> LBS.ByteString
renderTodosViewHtml links = renderBS . todosViewHtml links

todosViewHtml :: TodoLinks -> TodosView -> Html ()
todosViewHtml links todosView = todoPage links todosView.todos

renderTodoListViewHtml :: TodoLinks -> TodoListView -> LBS.ByteString
renderTodoListViewHtml links = renderBS . todoListViewHtml links

todoListViewHtml :: TodoLinks -> TodoListView -> Html ()
todoListViewHtml links listView =
  todoListSectionHighlightedOob
    links
    listView.todos
    listView.highlightedTodoId
    listView.outOfBand

renderTodoEditViewHtml :: TodoLinks -> TodoEditView -> LBS.ByteString
renderTodoEditViewHtml links = renderBS . todoEditViewHtml links

todoEditViewHtml :: TodoLinks -> TodoEditView -> Html ()
todoEditViewHtml links (TodoEditView todo) = todoEditForm links todo

renderTodoMutationViewHtml :: TodoLinks -> TodoMutationView -> LBS.ByteString
renderTodoMutationViewHtml links = renderBS . todoMutationViewHtml links

todoMutationViewHtml :: TodoLinks -> TodoMutationView -> Html ()
todoMutationViewHtml links mutationResult = case mutationResult.mutation of
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
      todoAddForm links Nothing
      todoListSectionHighlightedOob links mutationResult.todos mutationResult.highlightedTodoId True
    generationResponseHtml message = do
      todoAddForm links message
      todoListSectionHighlightedOob links mutationResult.todos Nothing True
    todoListHtml =
      todoListSectionWithOptions
        links
        mutationResult.todos
        mutationResult.highlightedTodoId
        False
        mutationResult.editingTodoId
        mutationResult.editingTitle

listSwap :: Text
listSwap = "outerMorph"

todoPage :: TodoLinks -> [Todo] -> Html ()
todoPage links items =
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
        {todoAddForm links Nothing}
      </header>
      {todoListSection links items}
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
  <script src={"/todo/" <> filterScriptFile} type="application/x-scittle"></script>
|]

todoAddForm :: TodoLinks -> Maybe Text -> Html ()
todoAddForm links message = [hsx|
  <form
    id="add-form"
    hx-post={links.linkTodos}
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
        hx-post={links.linkGenerate}
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

todoEditForm :: TodoLinks -> Todo -> Html ()
todoEditForm links todo = todoEditFormWithTitle links todo todo.title

todoEditFormWithTitle :: TodoLinks -> Todo -> Text -> Html ()
todoEditFormWithTitle links todo title' = [hsx|
  <li id={"todo-" <> show todo.id :: Text} class="editing">
    <form
      hx-put={links.linkItem todo.id}
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

todoListSection :: TodoLinks -> [Todo] -> Html ()
todoListSection links items =
  todoListSectionWithOptions links items Nothing False Nothing Nothing

todoListSectionHighlighted :: TodoLinks -> [Todo] -> Maybe Int64 -> Html ()
todoListSectionHighlighted links items highlightedTodoId =
  todoListSectionWithOptions links items highlightedTodoId False Nothing Nothing

todoListSectionHighlightedOob :: TodoLinks -> [Todo] -> Maybe Int64 -> Bool -> Html ()
todoListSectionHighlightedOob links items highlightedTodoId oob =
  todoListSectionWithOptions links items highlightedTodoId oob Nothing Nothing

todoListSectionWithOptions :: TodoLinks -> [Todo] -> Maybe Int64 -> Bool -> Maybe Int64 -> Maybe Text -> Html ()
todoListSectionWithOptions links items highlightedTodoId oob editingTodoId editingTitle =
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
      | Just todo.id == editingTodoId = todoEditFormWithTitle links todo (fromMaybe todo.title editingTitle)
      | otherwise = todoItemHighlighted links highlightedTodoId todo
    clearButton :: Html ()
    clearButton
      | completedCount > 0 = [hsx|
          <button
            class="clear-completed"
            hx-post={links.linkClear}
            hx-target="#todo-list"
            hx-swap={listSwap}
          >
            Clear completed
          </button>
        |]
      | otherwise = mempty

todoCountLabel :: Int -> Text
todoCountLabel n = (if n == 1 then "item" else "items") <> " left"

todoItem :: TodoLinks -> Todo -> Html ()
todoItem links = todoItemHighlighted links Nothing

todoItemHighlighted :: TodoLinks -> Maybe Int64 -> Todo -> Html ()
todoItemHighlighted links highlightedTodoId todo = [hsx|
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
    patchPath  = links.linkItem todo.id
    deletePath = links.linkItem todo.id
    editPath   = links.linkEdit todo.id
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
