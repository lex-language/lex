// Cliente LSP da extensão lex: inicia `lex lsp` por stdio e mostra os
// diagnósticos ao vivo no editor. O servidor está em `src/lsp.rs` do compilador.
import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext): void {
  context.subscriptions.push(
    vscode.commands.registerCommand("lex.restartServer", () => restart(context)),
  );
  start(context);
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}

async function restart(context: vscode.ExtensionContext): Promise<void> {
  await client?.stop();
  client = undefined;
  start(context);
}

function start(context: vscode.ExtensionContext): void {
  const command = resolveServerPath();
  if (!command) {
    vscode.window
      .showWarningMessage(
        "lex: não achei o binário do compilador. Rode `./selfhost/build-seed.sh` " +
          "ou configure `lex.server.path` para os diagnósticos ao vivo.",
        "Abrir configuração",
      )
      .then((choice) => {
        if (choice) {
          vscode.commands.executeCommand(
            "workbench.action.openSettings",
            "lex.server.path",
          );
        }
      });
    return;
  }

  // O `lex lsp` fala LSP por stdio (Content-Length + corpo JSON).
  const serverOptions: ServerOptions = {
    run: { command, args: ["lsp"], transport: TransportKind.stdio },
    debug: { command, args: ["lsp"], transport: TransportKind.stdio },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "lex" }],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher("**/*.lex"),
    },
  };

  client = new LanguageClient(
    "lex",
    "lex Language Server",
    serverOptions,
    clientOptions,
  );
  context.subscriptions.push(client);
  client.start();
}

// Ordem de resolução: 1) setting `lex.server.path`; 2) `bin/lex` em cada pasta do
// workspace (gerado por ./selfhost/build-seed.sh). NÃO cai pro PATH —
// em Unix `/usr/bin/lex` é o flex, não o compilador.
function resolveServerPath(): string | undefined {
  const configured = vscode.workspace
    .getConfiguration("lex")
    .get<string>("server.path")
    ?.trim();
  if (configured) {
    return configured;
  }

  const folders = vscode.workspace.workspaceFolders ?? [];
  for (const folder of folders) {
    const root = folder.uri.fsPath;
    for (const rel of ["bin/lex"]) {
      const candidate = path.join(root, rel);
      if (fs.existsSync(candidate)) {
        return candidate;
      }
    }
  }
  return undefined;
}
