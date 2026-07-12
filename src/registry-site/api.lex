// api — endpoints JSON do registry: índice, query string e publish.

import { Conn } from "http";
import { dataDir, pkgPath, safeName } from "./store";

// valor de um parâmetro da query string (`q=foo&x=1` → param "q" = "foo").
function qparam(query: string, key: string): string {
    const needle: string = `${key}=`;
    const idx: i64 = indexOf(query, needle);
    if (idx < 0) { return ""; }
    const after: string = substring(query, idx + len(needle), len(query));
    const amp: i64 = indexOf(after, "&");
    if (amp < 0) { return after; }
    return substring(after, 0, amp);
}

// índice inteiro em JSON (array de objetos).
function apiList(): string {
    const files: string[] = readDir(dataDir());
    const arr: json = jsonArray();
    for (const f of files) {
        if (endsWith(f, ".json")) {
            jsonPush(arr, jsonParse(readFile(`${dataDir()}/${f}`)));
        }
    }
    return jsonStringify(arr);
}

// publica: valida o corpo JSON, checa o token (se houver) e grava o pacote.
// responde 201 (ok), 400 (inválido) ou 401 (token errado). Retorna 0.
function publish(c: Conn): i64 {
    const b: json = jsonParse(c.body());
    const name: string = jsonAsStr(jsonGet(b, "name"));
    const repo: string = jsonAsStr(jsonGet(b, "repo"));
    if (safeName(name) == false || len(repo) == 0) {
        c.respondWith(400, "application/json", `{"error":"name and repo are required"}`);
        return 0;
    }
    // auth opcional: se existir data/.token, o corpo precisa do mesmo token.
    const tokenFile: string = `${dataDir()}/.token`;
    if (exists(tokenFile) == 1) {
        const want: string = trim(readFile(tokenFile));
        const got: string = jsonAsStr(jsonGet(b, "token"));
        if (strEq(want, got) == false) {
            c.respondWith(401, "application/json", `{"error":"invalid token"}`);
            return 0;
        }
    }
    let version: string = jsonAsStr(jsonGet(b, "version"));
    if (len(version) == 0) { version = "0.0.0"; }
    const desc: string = jsonAsStr(jsonGet(b, "description"));
    const obj: json = jsonObject();
    jsonSet(obj, "name", jsonStr(name));
    jsonSet(obj, "repo", jsonStr(repo));
    jsonSet(obj, "version", jsonStr(version));
    jsonSet(obj, "description", jsonStr(desc));
    writeFile(pkgPath(name), jsonStringify(obj));
    c.respondWith(201, "application/json", `{"ok":true,"name":"${name}","version":"${version}"}`);
    return 0;
}
