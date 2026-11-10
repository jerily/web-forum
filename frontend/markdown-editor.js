import {
  $createParagraphNode,
  $createTextNode,
  $getRoot,
  $getSelection,
  $isRangeSelection,
  CAN_REDO_COMMAND,
  CAN_UNDO_COMMAND,
  CLICK_COMMAND,
  COMMAND_PRIORITY_HIGH,
  COMMAND_PRIORITY_LOW,
  FORMAT_TEXT_COMMAND,
  REDO_COMMAND,
  SELECTION_CHANGE_COMMAND,
  UNDO_COMMAND,
  createEditor,
} from "lexical";
import { createEmptyHistoryState, registerHistory } from "@lexical/history";
import { $createLinkNode, $isLinkNode, $toggleLink, LinkNode } from "@lexical/link";
import {
  INSERT_ORDERED_LIST_COMMAND,
  INSERT_UNORDERED_LIST_COMMAND,
  ListItemNode,
  ListNode,
  REMOVE_LIST_COMMAND,
  registerList,
} from "@lexical/list";
import {
  $convertFromMarkdownString,
  $convertToMarkdownString,
  BOLD_STAR,
  BOLD_UNDERSCORE,
  HEADING,
  ITALIC_STAR,
  ITALIC_UNDERSCORE,
  LINK,
  ORDERED_LIST,
  QUOTE,
  UNORDERED_LIST,
  registerMarkdownShortcuts,
} from "@lexical/markdown";
import {
  $createHeadingNode,
  $createQuoteNode,
  $isHeadingNode,
  HeadingNode,
  QuoteNode,
  registerRichText,
} from "@lexical/rich-text";
import { $setBlocksType } from "@lexical/selection";
import { $findMatchingParent, $getNearestNodeOfType, mergeRegister } from "@lexical/utils";
import BoldIconSvg from "heroicons/24/outline/bold.svg";
import EyeIconSvg from "heroicons/24/outline/eye.svg";
import FileTextIconSvg from "heroicons/24/outline/document-text.svg";
import ItalicIconSvg from "heroicons/24/outline/italic.svg";
import LinkIconSvg from "heroicons/24/outline/link.svg";
import ListIconSvg from "heroicons/24/outline/list-bullet.svg";
import ListOrderedIconSvg from "heroicons/24/outline/numbered-list.svg";
import RedoIconSvg from "heroicons/24/outline/arrow-uturn-right.svg";
import UndoIconSvg from "heroicons/24/outline/arrow-uturn-left.svg";

const MARKDOWN_TRANSFORMERS = [
  HEADING,
  QUOTE,
  UNORDERED_LIST,
  ORDERED_LIST,
  BOLD_STAR,
  BOLD_UNDERSCORE,
  ITALIC_STAR,
  ITALIC_UNDERSCORE,
  LINK,
];

let editorSequence = 0;

// The shared rich editor covers headings, emphasis, lists, quotes and links.
// Keep other Markdown in the source textarea to avoid a lossy round trip.
function requiresSourceMode(markdown) {
  return /`|~~~|!\[|<[^>]+>|\||^ {4}\S|^\t|^\s*\[[^\]]+\]:|^\s*([-*_])(?:\s*\1){2,}\s*$|~~|^\s*[-*+] \[[ xX]\]/m.test(markdown);
}

function createSvgIcon(svgMarkup, className, size) {
  const template = document.createElement("template");
  template.innerHTML = svgMarkup.trim();
  const svg = template.content.firstElementChild;
  if (!(svg instanceof SVGElement)) {
    return null;
  }

  svg.classList.add(className);
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("focusable", "false");
  svg.setAttribute("height", String(size));
  svg.setAttribute("width", String(size));
  svg.removeAttribute("data-slot");
  return svg;
}

function createButton(label, command, title, options = {}) {
  const element = document.createElement("button");
  element.type = "button";
  element.className = [
    "markdown-editor__button",
    options.icon && !options.showLabel ? "markdown-editor__button--icon" : "",
  ].filter(Boolean).join(" ");
  if (options.icon) {
    const icon = createSvgIcon(options.icon, "markdown-editor__button-icon", 18);
    if (icon) {
      element.appendChild(icon);
    }
  }
  if (!options.icon || options.showLabel) {
    const labelElement = document.createElement("span");
    labelElement.textContent = label;
    labelElement.dataset.buttonLabel = "true";
    element.appendChild(labelElement);
  }
  element.dataset.command = command;
  element.title = title;
  element.setAttribute("aria-label", title);
  if (options.pressed) {
    element.setAttribute("aria-pressed", "false");
  }
  return element;
}

function setButtonLabel(button, label) {
  const labelElement = button.querySelector("[data-button-label]");
  if (labelElement) {
    labelElement.textContent = label;
  } else {
    button.textContent = label;
  }
}

function replaceButtonIcon(button, iconNode) {
  const currentIcon = button.querySelector(".markdown-editor__button-icon");
  if (!currentIcon) {
    return;
  }
  const icon = createSvgIcon(iconNode, "markdown-editor__button-icon", 18);
  if (icon) {
    button.replaceChild(icon, currentIcon);
  }
}

function createHeadingSelect() {
  const select = document.createElement("select");
  select.className = "markdown-editor__select";
  select.setAttribute("aria-label", "Block style");
  [
    ["paragraph", "Normal"],
    ["h1", "Heading 1"],
    ["h2", "Heading 2"],
    ["h3", "Heading 3"],
    ["quote", "Quote"],
  ].forEach(([value, label]) => {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = label;
    select.appendChild(option);
  });
  return select;
}

function setPressed(control, pressed) {
  control.classList.toggle("markdown-editor__button--active", pressed);
  control.setAttribute("aria-pressed", pressed ? "true" : "false");
}

function setControlsDisabled(controls, disabled) {
  controls.forEach((control) => {
    control.disabled = disabled;
  });
}

function normalizeMarkdown(value) {
  return String(value || "").replace(/\r\n?/g, "\n");
}

function selectedLinkNode(selection) {
  const node = selection.anchor.getNode();
  if ($isLinkNode(node)) {
    return node;
  }
  const parent = node.getParent();
  if ($isLinkNode(parent)) {
    return parent;
  }
  return $findMatchingParent(node, $isLinkNode);
}

function selectedListNode(anchorNode) {
  const topLevelElement = anchorNode.getTopLevelElement();
  if (topLevelElement instanceof ListNode) {
    return topLevelElement;
  }
  return $getNearestNodeOfType(anchorNode, ListNode);
}

function currentBlockType(selection) {
  const anchorNode = selection.anchor.getNode();
  const listNode = selectedListNode(anchorNode);
  if (listNode) {
    return listNode.getListType() === "number" ? "number" : "bullet";
  }

  const topLevelElement = anchorNode.getTopLevelElement();
  if ($isHeadingNode(topLevelElement)) {
    return topLevelElement.getTag();
  }
  if (topLevelElement instanceof QuoteNode) {
    return "quote";
  }
  return "paragraph";
}

function ensureEditableDocument() {
  const root = $getRoot();
  if (root.getChildrenSize() === 0) {
    root.append($createParagraphNode());
  }
}

function importMarkdown(markdown) {
  $convertFromMarkdownString(normalizeMarkdown(markdown), MARKDOWN_TRANSFORMERS);
  ensureEditableDocument();
}

function markdownFromEditorState() {
  return $convertToMarkdownString(MARKDOWN_TRANSFORMERS).trim();
}

function formatBlock(editor, blockType) {
  editor.update(() => {
    const selection = $getSelection();
    if (!$isRangeSelection(selection)) {
      return;
    }
    if (blockType === "paragraph") {
      $setBlocksType(selection, () => $createParagraphNode());
    } else if (blockType === "quote") {
      $setBlocksType(selection, () => $createQuoteNode());
    } else {
      $setBlocksType(selection, () => $createHeadingNode(blockType));
    }
  });
}

function promptForLink(editor) {
  editor.update(() => {
    const selection = $getSelection();
    if (!$isRangeSelection(selection)) {
      return;
    }

    const activeLink = selectedLinkNode(selection);
    const existingUrl = activeLink ? activeLink.getURL() : "";
    const nextUrl = window.prompt("URL", existingUrl);
    if (nextUrl === null) {
      return;
    }
    if (nextUrl.trim() === "") {
      $toggleLink(null);
      return;
    }

    if (activeLink && selection.isCollapsed()) {
      activeLink.setURL(nextUrl.trim());
      return;
    }

    if (selection.isCollapsed()) {
      const label = window.prompt("Link text", nextUrl.trim()) || nextUrl.trim();
      const linkNode = $createLinkNode(nextUrl.trim());
      linkNode.append($createTextNode(label));
      selection.insertNodes([linkNode]);
      return;
    }
    $toggleLink(nextUrl.trim());
  });
}

function dispatchListCommand(editor, listType, activeBlockType) {
  if (activeBlockType === listType) {
    editor.dispatchCommand(REMOVE_LIST_COMMAND, undefined);
    return;
  }
  editor.dispatchCommand(
    listType === "number" ? INSERT_ORDERED_LIST_COMMAND : INSERT_UNORDERED_LIST_COMMAND,
    undefined,
  );
}

function eventTargetElement(event) {
  const target = event.target;
  if (target instanceof Element) {
    return target;
  }
  if (target instanceof Node) {
    return target.parentElement;
  }
  return null;
}

function eventOccurredInsideElement(event, element) {
  const path = typeof event.composedPath === "function" ? event.composedPath() : [];
  if (path.length > 0) {
    return path.includes(element);
  }
  const target = event.target;
  return target === element || (target instanceof Node && element.contains(target));
}

function linkTargetInEditor(event, editorSurface) {
  const path = typeof event.composedPath === "function" ? event.composedPath() : [];
  for (const target of path) {
    if (target === editorSurface) {
      break;
    }
    if (target instanceof HTMLAnchorElement && editorSurface.contains(target)) {
      return target;
    }
    if (target instanceof Element) {
      const link = target.closest("a");
      if (link && editorSurface.contains(link)) {
        return link;
      }
    }
  }

  const element = eventTargetElement(event);
  const link = element ? element.closest("a") : null;
  return link && editorSurface.contains(link) ? link : null;
}

function setupMarkdownEditor(textarea) {
  if (textarea.dataset.markdownEditorReady === "true") {
    return;
  }
  textarea.dataset.markdownEditorReady = "true";

  const wrapper = document.createElement("div");
  wrapper.className = "markdown-editor";

  const toolbar = document.createElement("div");
  toolbar.className = "markdown-editor__toolbar";
  toolbar.setAttribute("role", "toolbar");
  toolbar.setAttribute("aria-label", "Markdown editor controls");

  const controls = {
    undo: createButton("Undo", "undo", "Undo", { icon: UndoIconSvg }),
    redo: createButton("Redo", "redo", "Redo", { icon: RedoIconSvg }),
    bold: createButton("Bold", "bold", "Bold", { icon: BoldIconSvg, pressed: true }),
    italic: createButton("Italic", "italic", "Italic", { icon: ItalicIconSvg, pressed: true }),
    bullet: createButton("Unordered list", "bullet", "Unordered list", { icon: ListIconSvg, pressed: true }),
    number: createButton("Ordered list", "number", "Ordered list", { icon: ListOrderedIconSvg, pressed: true }),
    link: createButton("Link", "link", "Create or edit link", { icon: LinkIconSvg, pressed: true }),
    source: createButton("Markdown", "source", "Edit Markdown source", {
      icon: FileTextIconSvg,
      pressed: true,
      showLabel: true,
    }),
  };
  controls.source.classList.add("markdown-editor__mode-button");
  const headingSelect = createHeadingSelect();
  const formatControls = [
    controls.bold,
    controls.italic,
    headingSelect,
    controls.bullet,
    controls.number,
    controls.link,
  ];

  [
    headingSelect,
    controls.undo,
    controls.redo,
    controls.bold,
    controls.italic,
    controls.bullet,
    controls.number,
    controls.link,
    controls.source,
  ].forEach((control) => toolbar.appendChild(control));

  const editorSurface = document.createElement("div");
  editorSurface.className = "markdown-editor__surface";
  editorSurface.contentEditable = "true";
  editorSurface.setAttribute("aria-label", "Markdown editor");
  editorSurface.setAttribute("spellcheck", "true");

  textarea.classList.add("markdown-editor__textarea");
  textarea.hidden = true;
  textarea.insertAdjacentElement("afterend", wrapper);
  const notice = document.createElement("p");
  notice.className = "editor-notice";
  notice.textContent = "This document uses Markdown features edited in source mode, including tables, code, images or HTML. Your original source is preserved.";
  notice.hidden = true;
  wrapper.append(toolbar, notice, editorSurface, textarea);

  const editor = createEditor({
    namespace: `WebMarkdownEditor${++editorSequence}`,
    nodes: [HeadingNode, QuoteNode, ListNode, ListItemNode, LinkNode],
    onError(error) {
      throw error;
    },
    theme: {
      heading: {
        h1: "markdown-editor__heading markdown-editor__heading--h1",
        h2: "markdown-editor__heading markdown-editor__heading--h2",
        h3: "markdown-editor__heading markdown-editor__heading--h3",
      },
      link: "markdown-editor__link",
      list: {
        listitem: "markdown-editor__list-item",
        ol: "markdown-editor__list markdown-editor__list--ordered",
        ul: "markdown-editor__list markdown-editor__list--unordered",
      },
      paragraph: "markdown-editor__paragraph",
      quote: "markdown-editor__quote",
      text: {
        bold: "markdown-editor__text--bold",
        italic: "markdown-editor__text--italic",
      },
    },
  });

  let sourceMode = false;
  let hasRichEdits = false;
  let activeBlockType = "paragraph";
  let canUndo = false;
  let canRedo = false;
  let surfacePointerFocusPending = false;

  function scheduleRichEditorFocus() {
    if (sourceMode) {
      return;
    }

    const focusIfNeeded = () => {
      if (!sourceMode && document.activeElement !== editorSurface) {
        editor.focus();
      }
    };

    if (typeof queueMicrotask === "function") {
      queueMicrotask(focusIfNeeded);
    }
    window.requestAnimationFrame(focusIfNeeded);
    window.setTimeout(focusIfNeeded, 0);
  }

  function keepRichEditorFocused() {
    if (sourceMode) {
      return;
    }
    editor.focus();
    scheduleRichEditorFocus();
  }

  function updateControlAvailability() {
    setControlsDisabled(formatControls, sourceMode);
    controls.undo.disabled = sourceMode || !canUndo;
    controls.redo.disabled = sourceMode || !canRedo;
  }

  function syncTextareaFromEditorState(editorState = editor.getEditorState()) {
    if (sourceMode || !hasRichEdits) {
      return;
    }
    editorState.read(() => {
      textarea.value = markdownFromEditorState();
    });
  }

  function syncEditorFromTextarea() {
    hasRichEdits = false;
    editor.update(() => {
      importMarkdown(textarea.value);
    }, { tag: "import-markdown", discrete: true });
  }

  function updateToolbarState(editorState = editor.getEditorState()) {
    if (sourceMode) {
      return;
    }
    editorState.read(() => {
      const selection = $getSelection();
      if (!$isRangeSelection(selection)) {
        setPressed(controls.bold, false);
        setPressed(controls.italic, false);
        setPressed(controls.link, false);
        setPressed(controls.bullet, false);
        setPressed(controls.number, false);
        headingSelect.value = "paragraph";
        activeBlockType = "paragraph";
        return;
      }

      activeBlockType = currentBlockType(selection);
      setPressed(controls.bold, selection.hasFormat("bold"));
      setPressed(controls.italic, selection.hasFormat("italic"));
      setPressed(controls.link, selectedLinkNode(selection) !== null);
      setPressed(controls.bullet, activeBlockType === "bullet");
      setPressed(controls.number, activeBlockType === "number");
      headingSelect.value = ["h1", "h2", "h3", "quote"].includes(activeBlockType)
        ? activeBlockType
        : "paragraph";
    });
  }

  function setSourceMode(nextSourceMode) {
    if (!nextSourceMode && requiresSourceMode(textarea.value)) {
      return;
    }
    if (nextSourceMode) {
      syncTextareaFromEditorState();
    }
    sourceMode = nextSourceMode;
    notice.hidden = !sourceMode || !requiresSourceMode(textarea.value);
    controls.source.disabled = sourceMode && requiresSourceMode(textarea.value);
    if (sourceMode) {
      editorSurface.hidden = true;
      textarea.hidden = false;
      setButtonLabel(controls.source, "Preview");
      replaceButtonIcon(controls.source, EyeIconSvg);
      controls.source.title = "Return to rich editor";
      controls.source.setAttribute("aria-label", "Return to rich editor");
      setPressed(controls.source, true);
      updateControlAvailability();
      textarea.focus();
      return;
    }

    editorSurface.hidden = false;
    textarea.hidden = true;
    setButtonLabel(controls.source, "Markdown");
    replaceButtonIcon(controls.source, FileTextIconSvg);
    controls.source.title = "Edit Markdown source";
    controls.source.setAttribute("aria-label", "Edit Markdown source");
    setPressed(controls.source, false);
    updateControlAvailability();
    syncEditorFromTextarea();
    editor.focus();
  }

  editor.setRootElement(editorSurface);
  mergeRegister(
    registerRichText(editor),
    registerList(editor),
    registerHistory(editor, createEmptyHistoryState(), 300),
    registerMarkdownShortcuts(editor, MARKDOWN_TRANSFORMERS),
    editor.registerCommand(
      CLICK_COMMAND,
      (event) => {
        if (!linkTargetInEditor(event, editorSurface)) {
          return false;
        }

        if (event.cancelable) {
          event.preventDefault();
        }
        event.stopPropagation();
        keepRichEditorFocused();
        return true;
      },
      COMMAND_PRIORITY_HIGH,
    ),
    editor.registerCommand(
      SELECTION_CHANGE_COMMAND,
      () => {
        updateToolbarState();
        return false;
      },
      COMMAND_PRIORITY_LOW,
    ),
    editor.registerCommand(
      CAN_UNDO_COMMAND,
      (nextCanUndo) => {
        canUndo = Boolean(nextCanUndo);
        updateControlAvailability();
        return false;
      },
      COMMAND_PRIORITY_LOW,
    ),
    editor.registerCommand(
      CAN_REDO_COMMAND,
      (nextCanRedo) => {
        canRedo = Boolean(nextCanRedo);
        updateControlAvailability();
        return false;
      },
      COMMAND_PRIORITY_LOW,
    ),
    editor.registerUpdateListener(({ editorState, tags, dirtyElements, dirtyLeaves }) => {
      if (!tags.has("import-markdown") && (dirtyElements.size || dirtyLeaves.size)) {
        hasRichEdits = true;
      }
      syncTextareaFromEditorState(editorState);
      updateToolbarState(editorState);
    }),
  );

  function queueSurfacePointerFocus() {
    surfacePointerFocusPending = true;
    window.setTimeout(() => {
      surfacePointerFocusPending = false;
    }, 350);
  }

  function handleEditorSurfacePointer(event) {
    if (!eventOccurredInsideElement(event, editorSurface)) {
      return;
    }

    queueSurfacePointerFocus();
    const link = linkTargetInEditor(event, editorSurface);
    if (link) {
      if (event.cancelable) {
        event.preventDefault();
      }
      event.stopPropagation();
      keepRichEditorFocused();
      return;
    }

    scheduleRichEditorFocus();
  }

  function handleEditorSurfaceClick(event) {
    if (!eventOccurredInsideElement(event, editorSurface)) {
      return;
    }

    const link = linkTargetInEditor(event, editorSurface);
    if (link) {
      if (event.cancelable) {
        event.preventDefault();
      }
      event.stopPropagation();
      keepRichEditorFocused();
      return;
    }

    scheduleRichEditorFocus();
  }

  editorSurface.addEventListener("pointerdown", handleEditorSurfacePointer, true);
  editorSurface.addEventListener("mousedown", handleEditorSurfacePointer, true);
  editorSurface.addEventListener("click", handleEditorSurfaceClick, true);
  editorSurface.addEventListener("focusout", () => {
    if (surfacePointerFocusPending) {
      scheduleRichEditorFocus();
    }
  });
  document.addEventListener(
    "pointerdown",
    (event) => {
      if (!eventOccurredInsideElement(event, editorSurface)) {
        surfacePointerFocusPending = false;
      }
    },
    true,
  );

  toolbar.addEventListener("mousedown", (event) => {
    const control = event.target instanceof Element ? event.target.closest("[data-command]") : null;
    if (control) {
      event.preventDefault();
    }
  });

  toolbar.addEventListener("click", (event) => {
    const control = event.target instanceof Element ? event.target.closest("[data-command]") : null;
    if (!control || control.disabled) {
      return;
    }

    const command = control.dataset.command || "";
    if (command === "source") {
      setSourceMode(!sourceMode);
    } else if (command === "undo") {
      editor.dispatchCommand(UNDO_COMMAND, undefined);
    } else if (command === "redo") {
      editor.dispatchCommand(REDO_COMMAND, undefined);
    } else if (command === "bold" || command === "italic") {
      editor.dispatchCommand(FORMAT_TEXT_COMMAND, command);
    } else if (command === "bullet" || command === "number") {
      dispatchListCommand(editor, command, activeBlockType);
    } else if (command === "link") {
      promptForLink(editor);
    }
  });

  headingSelect.addEventListener("change", () => {
    formatBlock(editor, headingSelect.value);
    keepRichEditorFocused();
  });

  textarea.addEventListener("input", () => {
    if (!sourceMode) {
      syncEditorFromTextarea();
    } else {
      controls.source.disabled = requiresSourceMode(textarea.value);
      notice.hidden = !requiresSourceMode(textarea.value);
    }
  });

  const form = textarea.closest("form");
  if (form) {
    form.addEventListener("submit", () => {
      syncTextareaFromEditorState();
    });
  }

  if (requiresSourceMode(textarea.value)) {
    setSourceMode(true);
  } else {
    syncEditorFromTextarea();
  }
  updateControlAvailability();
}

if (typeof document !== "undefined") {
  document.addEventListener("DOMContentLoaded", () => {
    document.querySelectorAll("textarea[data-markdown-editor]").forEach(setupMarkdownEditor);
  });
}
