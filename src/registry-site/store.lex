// store — configuração e helpers do diretório de dados do registry.
//
// Cada pacote é um arquivo `data/<nome>.json` = { name, repo, version,
// description }. lex não tem estado de módulo, então as constantes são funções.

function dataDir(): string { return "data"; }
function port(): i64 { return 8080; }

// nome de pacote seguro: sem barra nem ".." (evita escapar do diretório data/).
function safeName(name: string): bool {
    if (len(name) == 0) { return false; }
    if (contains(name, "/")) { return false; }
    if (contains(name, "..")) { return false; }
    return true;
}

// caminho do arquivo JSON de um pacote.
function pkgPath(name: string): string {
    return `${dataDir()}/${name}.json`;
}
