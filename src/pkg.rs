//! lex pkg — o gerenciador de pacotes da linguagem lex.
//!
//! Subcomandos do binário `lex` (despachados por `main.rs`):
//!   lex init                      cria um lex.toml no diretório atual
//!   lex add <nome|url|file:>[@v]  adiciona uma dependência e instala
//!   lex install                   instala tudo do lex.toml (respeita o lex.lock)
//!   lex remove <nome>             remove uma dependência (e o que ficou órfão)
//!   lex update [nome]             re-resolve para a versão mais nova compatível
//!   lex list                      lista o que está instalado
//!
//! Fontes de pacote suportadas:
//!   - registry: `cores = "^1.2.0"`     resolvido pelo índice em ~/.lex/registry
//!   - git:      `cores = "github.com/joao/cores@^1.2.0"`  (URL direta, com ref/semver)
//!   - local:    `cores = "file:../cores"`                  (cópia de uma pasta)
//!
//! Toda a rede passa pelo `git` (ls-remote para listar versões, clone para
//! baixar). Não há crate de HTTP/TLS: o índice do registry é um repo git clonado
//! em ~/.lex/registry e lido localmente. O commit fixado no lex.lock é a
//! garantia de integridade (reprodutibilidade).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use semver::{Version, VersionReq};
use serde::{Deserialize, Serialize};

use crate::diag;

/// Arquivo de manifesto do projeto (declarado pelo humano).
pub const MANIFEST: &str = "lex.toml";
/// Lockfile: versões/commits exatos resolvidos (reprodutível).
pub const LOCKFILE: &str = "lex.lock";
/// Onde os pacotes baixados ficam (por projeto, estilo node_modules).
pub const MODULES_DIR: &str = "lex_modules";
/// Repo git do índice do registry (nome -> URL). Sobrescrevível por LEX_REGISTRY.
const DEFAULT_REGISTRY: &str = "https://github.com/lex-language/registry";

/// URL base do registry como SITE (API HTTP em lex; ver registry-site/). Quando
/// definida (aqui ou via `LEX_REGISTRY_API`), `lex add`/`lex publish` falam com
/// a API JSON (`GET /api/pkg/<nome>`, `POST /api/publish`) em vez do índice git.
/// Vazio = usa o índice git acima. Preencher quando o site estiver hospedado.
const DEFAULT_REGISTRY_API: &str = "";

// ===========================================================================
// Manifesto (lex.toml)
// ===========================================================================

#[derive(Debug, Serialize, Deserialize)]
struct Manifest {
    package: PackageMeta,
    #[serde(default)]
    dependencies: BTreeMap<String, String>,
}

#[derive(Debug, Serialize, Deserialize)]
struct PackageMeta {
    name: String,
    version: String,
    /// Ponto de entrada do pacote (o que `import { } from "nome"` resolve).
    /// Opcional: na ausência, tentam-se convenções (<nome>.lex, main.lex, …).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    main: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    description: Option<String>,
}

// ===========================================================================
// Lockfile (lex.lock)
// ===========================================================================

#[derive(Debug, Default, Serialize, Deserialize)]
struct Lockfile {
    #[serde(default, rename = "package")]
    packages: Vec<LockedPkg>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct LockedPkg {
    name: String,
    version: String,
    /// "registry", "git" ou "file" — de onde veio.
    source: String,
    /// URL/caminho concreto de onde foi baixado.
    resolved: String,
    /// Commit git fixado (ou "local" para fontes file:). É a integridade.
    commit: String,
    /// Nomes das dependências diretas deste pacote (para coleta de órfãos).
    #[serde(default)]
    dependencies: Vec<String>,
}

impl Lockfile {
    fn find(&self, name: &str) -> Option<&LockedPkg> {
        self.packages.iter().find(|p| p.name == name)
    }
    fn upsert(&mut self, pkg: LockedPkg) {
        if let Some(slot) = self.packages.iter_mut().find(|p| p.name == pkg.name) {
            *slot = pkg;
        } else {
            self.packages.push(pkg);
        }
        self.packages.sort_by(|a, b| a.name.cmp(&b.name));
    }
}

// ===========================================================================
// Fonte de uma dependência (interpretação do valor do lex.toml / da CLI)
// ===========================================================================

enum DepSource {
    /// Resolvida pelo índice do registry; restrição de versão por semver.
    Registry(VersionReq),
    /// URL git direta. `reference` é um semver (escolhe a tag) ou um ref literal
    /// (branch/tag) quando não for um semver válido.
    Git { url: String, reference: GitRef },
    /// Pasta local copiada para dentro de lex_modules/.
    Path(String),
}

enum GitRef {
    /// Restrição semver: a versão é escolhida entre as tags do repo.
    Semver(VersionReq),
    /// Branch/tag literal (ex.: "main", "v2-beta").
    Named(String),
    /// Sem ref: usa o branch padrão (HEAD).
    Default,
}

/// Interpreta o valor de uma dependência (string do lex.toml ou argumento da
/// CLI) em (nome inferido, fonte, valor canônico p/ gravar no manifesto).
///
/// `name_hint` é o nome quando já conhecido (chave do lex.toml); para `lex add`
/// de uma URL/path o nome é inferido do último segmento.
fn parse_dep(name_hint: Option<&str>, spec: &str) -> (String, DepSource, String) {
    // file:../algum/dir  ->  fonte local
    if let Some(rest) = spec.strip_prefix("file:") {
        let name = name_hint
            .map(str::to_string)
            .unwrap_or_else(|| last_segment(rest));
        return (name, DepSource::Path(rest.to_string()), spec.to_string());
    }

    // URL-ish: contém "/" (ou esquema). Senão é um nome do registry.
    let looks_url = spec.contains('/')
        || spec.starts_with("http://")
        || spec.starts_with("https://")
        || spec.starts_with("git@")
        || spec.starts_with("git:");

    if looks_url {
        let raw = spec.strip_prefix("git:").unwrap_or(spec);
        // separa "...repo@ref". O '@' do esquema git@host não conta.
        let (url_part, ref_part) = split_at_marker(raw);
        let url = normalize_git_url(url_part);
        let name = name_hint
            .map(str::to_string)
            .unwrap_or_else(|| last_segment(url_part).trim_end_matches(".git").to_string());
        let reference = match ref_part {
            None => GitRef::Default,
            Some(r) => match VersionReq::parse(r) {
                Ok(req) => GitRef::Semver(req),
                Err(_) => GitRef::Named(r.to_string()),
            },
        };
        let canonical = format!("{}{}", url_part, ref_part.map(|r| format!("@{}", r)).unwrap_or_default());
        return (name, DepSource::Git { url, reference }, canonical);
    }

    // registry: "nome" (na CLI) ou só a restrição (valor do lex.toml). O nome
    // vem do name_hint; quando ausente (CLI `lex add cores@^1`), o próprio spec
    // antes do '@' é o nome.
    let (head, ver) = split_at_marker(spec);
    let name = name_hint.map(str::to_string).unwrap_or_else(|| head.to_string());
    let req_str = ver.unwrap_or("*");
    let req = VersionReq::parse(req_str)
        .unwrap_or_else(|e| fail(&format!("invalid version requirement '{}': {}", req_str, e)));
    (name, DepSource::Registry(req), req_str.to_string())
}

/// Separa "algo@resto" no PRIMEIRO '@' que não seja o do "git@host". Devolve
/// (parte antes, Some(parte depois)) ou (tudo, None) se não houver '@' útil.
fn split_at_marker(s: &str) -> (&str, Option<&str>) {
    // ignora um eventual "git@" inicial (scp-like)
    let start = if s.starts_with("git@") { 4 } else { 0 };
    match s[start..].find('@') {
        Some(rel) => {
            let at = start + rel;
            (&s[..at], Some(&s[at + 1..]))
        }
        None => (s, None),
    }
}

/// Último segmento de um caminho/URL (sem barra final).
fn last_segment(s: &str) -> String {
    s.trim_end_matches('/')
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(s)
        .to_string()
}

/// Garante um esquema clonável: "github.com/u/r" -> "https://github.com/u/r".
/// URLs já com esquema (http/https/git@/ssh) passam intactas.
fn normalize_git_url(u: &str) -> String {
    if u.starts_with("http://")
        || u.starts_with("https://")
        || u.starts_with("git@")
        || u.starts_with("ssh://")
        || u.starts_with("git://")
        // caminhos locais (git clona deles direto): não levam esquema
        || u.starts_with("file://")
        || u.starts_with('/')
        || u.starts_with("./")
        || u.starts_with("../")
    {
        u.to_string()
    } else {
        format!("https://{}", u)
    }
}

// ===========================================================================
// Dispatcher dos subcomandos
// ===========================================================================

/// Os subcomandos do gerenciador. `main.rs` consulta isto para decidir se o
/// primeiro argumento é um comando de pacotes (em vez de um arquivo a compilar).
pub fn is_subcommand(arg: &str) -> bool {
    matches!(
        arg,
        "init" | "install" | "i" | "add" | "remove" | "uninstall" | "rm"
            | "update" | "upgrade" | "list" | "ls" | "registry" | "publish"
    )
}

/// Ponto de entrada: recebe o argv completo (args[1] é o subcomando).
pub fn run(args: &[String]) -> ! {
    let cmd = args[1].as_str();
    let rest = &args[2..];
    match cmd {
        "init" => cmd_init(rest),
        "install" | "i" => cmd_install(rest),
        "add" => cmd_add(rest),
        "remove" | "uninstall" | "rm" => cmd_remove(rest),
        "update" | "upgrade" => cmd_update(rest),
        "list" | "ls" => cmd_list(),
        "registry" => cmd_registry(rest),
        "publish" => cmd_publish(rest),
        _ => fail(&format!("unknown command '{}'", cmd)),
    }
    std::process::exit(0);
}

// ===========================================================================
// init
// ===========================================================================

fn cmd_init(_args: &[String]) {
    if Path::new(MANIFEST).exists() {
        fail(&format!("{} already exists here", MANIFEST));
    }
    // nome default = nome da pasta atual
    let name = std::env::current_dir()
        .ok()
        .and_then(|d| d.file_name().map(|n| n.to_string_lossy().to_string()))
        .unwrap_or_else(|| "app".to_string());
    let manifest = Manifest {
        package: PackageMeta {
            name: name.clone(),
            version: "0.1.0".to_string(),
            main: None,
            description: None,
        },
        dependencies: BTreeMap::new(),
    };
    save_manifest(&manifest);
    println!("{}", diag::ok_line(&format!("created {} ({})", MANIFEST, name)));
}

// ===========================================================================
// add
// ===========================================================================

fn cmd_add(args: &[String]) {
    if args.is_empty() {
        fail("add requires at least one package: lex add <name|url|file:path>[@version]");
    }
    let mut manifest = load_manifest();
    let mut lock = load_lock();

    for spec in args {
        let (name, source, canonical) = parse_dep(None, spec);
        // resolve + baixa já, para falhar cedo se o pacote não existir
        let locked = resolve_and_fetch(&name, &source, &mut lock);
        // grava no manifesto: para registry sem versão explícita, fixa "^x.y.z"
        let value = match &source {
            DepSource::Registry(req) if req == &VersionReq::STAR => format!("^{}", locked.version),
            _ => canonical,
        };
        manifest.dependencies.insert(name.clone(), value);
        println!("{}", diag::ok_line(&format!("added {} {}", name, locked.version)));
    }

    save_manifest(&manifest);
    install_transitive(&mut lock);
    prune_orphans(&manifest, &mut lock);
    save_lock(&lock);
}

// ===========================================================================
// install
// ===========================================================================

fn cmd_install(_args: &[String]) {
    let manifest = load_manifest();
    let mut lock = load_lock();

    if manifest.dependencies.is_empty() {
        println!("{}", diag::ok_line("no dependencies"));
        return;
    }

    for (name, spec) in &manifest.dependencies {
        let (_, source, _) = parse_dep(Some(name), spec);
        // se já está no lock E presente em disco, reusa (reprodutível).
        let present = lock.find(name).is_some() && Path::new(MODULES_DIR).join(name).is_dir();
        if present {
            // garante o conteúdo em disco a partir do lock (caso falte)
            ensure_installed_from_lock(name, &mut lock);
        } else {
            resolve_and_fetch(name, &source, &mut lock);
        }
    }

    install_transitive(&mut lock);
    prune_orphans(&manifest, &mut lock);
    save_lock(&lock);
    println!(
        "{}",
        diag::ok_line(&format!("installed {} package(s)", lock.packages.len()))
    );
}

// ===========================================================================
// remove
// ===========================================================================

fn cmd_remove(args: &[String]) {
    if args.is_empty() {
        fail("remove requires a package name: lex remove <name>");
    }
    let mut manifest = load_manifest();
    let mut lock = load_lock();

    for name in args {
        if manifest.dependencies.remove(name).is_none() {
            eprintln!("{}", diag::fail_line(&format!("'{}' is not a dependency", name)));
            continue;
        }
        println!("{}", diag::ok_line(&format!("removed {}", name)));
    }

    save_manifest(&manifest);
    prune_orphans(&manifest, &mut lock);
    save_lock(&lock);
}

// ===========================================================================
// update
// ===========================================================================

fn cmd_update(args: &[String]) {
    let manifest = load_manifest();
    let mut lock = load_lock();

    let targets: Vec<String> = if args.is_empty() {
        manifest.dependencies.keys().cloned().collect()
    } else {
        args.to_vec()
    };

    for name in &targets {
        let Some(spec) = manifest.dependencies.get(name) else {
            eprintln!("{}", diag::fail_line(&format!("'{}' is not a dependency", name)));
            continue;
        };
        let (_, source, _) = parse_dep(Some(name), spec);
        // tira o pin do lock para forçar re-resolução pela restrição do manifesto
        lock.packages.retain(|p| &p.name != name);
        let locked = resolve_and_fetch(name, &source, &mut lock);
        println!("{}", diag::ok_line(&format!("{} -> {}", name, locked.version)));
    }

    install_transitive(&mut lock);
    prune_orphans(&manifest, &mut lock);
    save_lock(&lock);
}

// ===========================================================================
// list
// ===========================================================================

fn cmd_list() {
    let manifest = load_manifest();
    let lock = load_lock();
    println!("{} {}", manifest.package.name, manifest.package.version);
    if lock.packages.is_empty() {
        println!("{}", diag::dim_line("  (no packages installed — run `lex install`)"));
        return;
    }
    let direct: std::collections::BTreeSet<&String> = manifest.dependencies.keys().collect();
    for p in &lock.packages {
        let mark = if direct.contains(&p.name) { "" } else { " (transitive)" };
        println!("  {} {} [{}]{}", p.name, p.version, p.source, mark);
    }
}

// ===========================================================================
// Resolução + download
// ===========================================================================

/// Resolve a fonte para uma versão concreta, baixa para lex_modules/<name>/ e
/// atualiza o lockfile. Devolve o registro do lock (clonado).
fn resolve_and_fetch(name: &str, source: &DepSource, lock: &mut Lockfile) -> LockedPkg {
    let dest = Path::new(MODULES_DIR).join(name);

    let locked = match source {
        DepSource::Path(dir) => {
            let src = PathBuf::from(dir);
            if !src.is_dir() {
                fail(&format!("local path '{}' is not a directory", dir));
            }
            wipe(&dest);
            copy_dir(&src, &dest);
            let version = read_pkg_version(&dest).unwrap_or_else(|| "0.0.0".to_string());
            LockedPkg {
                name: name.to_string(),
                version,
                source: "file".to_string(),
                resolved: dir.clone(),
                commit: "local".to_string(),
                dependencies: read_pkg_dep_names(&dest),
            }
        }
        DepSource::Git { url, reference } => fetch_git(name, url, reference, &dest),
        DepSource::Registry(req) => {
            let url = registry_lookup(name);
            fetch_git(name, &url, &GitRef::Semver(req.clone()), &dest)
        }
    };

    lock.upsert(locked.clone());
    locked
}

/// Clona um repo git no ref/versão pedido. Captura o commit (integridade) e
/// remove o .git para deixar lex_modules/ limpo.
fn fetch_git(name: &str, url: &str, reference: &GitRef, dest: &Path) -> LockedPkg {
    // escolhe a tag a clonar
    let (version, tag): (String, Option<String>) = match reference {
        GitRef::Default => ("0.0.0".to_string(), None),
        GitRef::Named(r) => (r.clone(), Some(r.clone())),
        GitRef::Semver(req) => {
            let tags = git_ls_tags(url);
            let (v, tag) = pick_version(&tags, req).unwrap_or_else(|| {
                fail(&format!(
                    "no version of '{}' matches '{}' (tags: {})",
                    name,
                    req,
                    if tags.is_empty() {
                        "none".to_string()
                    } else {
                        tags.iter().map(|(v, _)| v.to_string()).collect::<Vec<_>>().join(", ")
                    }
                ))
            });
            (v.to_string(), Some(tag))
        }
    };

    wipe(dest);
    let mut clone = vec!["clone", "--depth", "1", "--quiet"];
    if let Some(t) = &tag {
        clone.push("--branch");
        clone.push(t);
    }
    clone.push(url);
    let dest_str = dest.to_string_lossy().to_string();
    clone.push(&dest_str);
    git(&clone).unwrap_or_else(|e| {
        wipe(dest);
        fail(&format!("failed to fetch '{}' from {}: {}", name, url, e))
    });

    // commit fixado = integridade
    let commit = git_capture(&["-C", &dest_str, "rev-parse", "HEAD"])
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "unknown".to_string());

    // descobre a versão real pelo lex.toml do pacote, se houver
    let version = read_pkg_version(dest).unwrap_or(version);
    let deps = read_pkg_dep_names(dest);

    // limpa o histórico git (não queremos um repo dentro de lex_modules/)
    wipe(&dest.join(".git"));

    LockedPkg {
        name: name.to_string(),
        version,
        source: if matches!(reference, GitRef::Semver(_)) { "registry-or-git" } else { "git" }
            .to_string(),
        resolved: url.to_string(),
        commit,
        dependencies: deps,
    }
}

/// Reinstala um pacote a partir do que está no lockfile (commit/versão exatos).
fn ensure_installed_from_lock(name: &str, lock: &mut Lockfile) {
    let dest = Path::new(MODULES_DIR).join(name);
    if dest.is_dir() {
        return;
    }
    let Some(p) = lock.find(name).cloned() else { return };
    match p.source.as_str() {
        "file" => {
            let src = PathBuf::from(&p.resolved);
            if src.is_dir() {
                copy_dir(&src, &dest);
            }
        }
        _ => {
            // clona e dá checkout no commit fixado (reprodutível)
            let dest_str = dest.to_string_lossy().to_string();
            let _ = git(&["clone", "--quiet", &p.resolved, &dest_str]).and_then(|_| {
                git(&["-C", &dest_str, "checkout", "--quiet", &p.commit])
            });
            wipe(&dest.join(".git"));
        }
    }
}

/// Resolve dependências transitivas: percorre os pacotes já no lock, lê o
/// lex.toml de cada um e instala o que faltar (achatado em lex_modules/).
fn install_transitive(lock: &mut Lockfile) {
    let mut i = 0;
    // o lock cresce conforme novos transitivos entram; varre até estabilizar
    while i < lock.packages.len() {
        let pkg = lock.packages[i].clone();
        let dir = Path::new(MODULES_DIR).join(&pkg.name);
        let deps = read_pkg_deps(&dir); // (nome -> spec) do lex.toml do pacote
        for (dname, dspec) in deps {
            let already = lock.find(&dname).is_some()
                && Path::new(MODULES_DIR).join(&dname).is_dir();
            if already {
                continue;
            }
            let (_, source, _) = parse_dep(Some(&dname), &dspec);
            resolve_and_fetch(&dname, &source, lock);
        }
        i += 1;
    }
}

/// Remove de lex_modules/ e do lock tudo que não é alcançável a partir das
/// dependências diretas do manifesto (via o grafo gravado no lock).
fn prune_orphans(manifest: &Manifest, lock: &mut Lockfile) {
    // conjunto alcançável: BFS a partir das deps diretas
    let mut keep = std::collections::BTreeSet::new();
    let mut stack: Vec<String> = manifest.dependencies.keys().cloned().collect();
    while let Some(n) = stack.pop() {
        if !keep.insert(n.clone()) {
            continue;
        }
        if let Some(p) = lock.find(&n) {
            for d in &p.dependencies {
                stack.push(d.clone());
            }
        }
    }

    // apaga do lock o que não fica
    lock.packages.retain(|p| keep.contains(&p.name));

    // apaga do disco os diretórios órfãos
    if let Ok(entries) = std::fs::read_dir(MODULES_DIR) {
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if !keep.contains(&name) && e.path().is_dir() {
                wipe(&e.path());
            }
        }
    }
}

// ===========================================================================
// Registry (índice em ~/.lex/registry)
// ===========================================================================

/// URL base do registry-site (API HTTP), se configurada. `LEX_REGISTRY_API` tem
/// prioridade; senão usa `DEFAULT_REGISTRY_API` (se não-vazio). `None` = modo
/// índice git. A barra final é removida para concatenar caminhos com `/api/...`.
fn registry_api() -> Option<String> {
    let raw = std::env::var("LEX_REGISTRY_API")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_REGISTRY_API.to_string());
    let raw = raw.trim().trim_end_matches('/').to_string();
    if raw.is_empty() { None } else { Some(raw) }
}

/// `curl` GET (rede via processo externo, como o `git`). `-f` falha em 4xx/5xx.
fn curl_get(url: &str) -> Result<String, String> {
    let out = Command::new("curl")
        .args(["-fsSL", url])
        .output()
        .map_err(|e| format!("could not run curl ({}). is curl installed?", e))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(format!(
            "GET {} failed: {}",
            url,
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

/// `curl` POST de um corpo JSON para `url`.
fn curl_post_json(url: &str, body: &str) -> Result<String, String> {
    let out = Command::new("curl")
        .args([
            "-fsSL",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "--data-binary",
            body,
            url,
        ])
        .output()
        .map_err(|e| format!("could not run curl ({}). is curl installed?", e))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(format!(
            "POST {} failed: {}",
            url,
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

/// Resolve um nome do registry para a URL git do repo. Pelo SITE (API HTTP) se
/// `registry_api()` estiver configurado; senão pelo índice git clonado.
fn registry_lookup(name: &str) -> String {
    if let Some(api) = registry_api() {
        return registry_lookup_http(&api, name);
    }
    let index = ensure_registry();
    // o índice expõe packages/<nome>.toml com { repo = "..." }
    let entry = index.join("packages").join(format!("{}.toml", name));
    let text = std::fs::read_to_string(&entry).unwrap_or_else(|_| {
        fail(&format!(
            "package '{}' not found in the registry index\n  (looked for {})\n  tip: install by git URL instead: lex add github.com/user/{}",
            name,
            entry.display(),
            name
        ))
    });
    #[derive(Deserialize)]
    struct Entry {
        repo: String,
    }
    let parsed: Entry = toml::from_str(&text)
        .unwrap_or_else(|e| fail(&format!("malformed registry entry for '{}': {}", name, e)));
    normalize_git_url(&parsed.repo)
}

/// Resolve um nome pela API do registry-site: `GET {api}/api/pkg/<nome>` →
/// JSON `{ repo, ... }` → URL git do pacote (que o resto baixa por tags).
fn registry_lookup_http(api: &str, name: &str) -> String {
    let url = format!("{}/api/pkg/{}", api, name);
    let body = curl_get(&url).unwrap_or_else(|e| {
        fail(&format!(
            "package '{}' not found in the registry at {}\n  ({})\n  tip: install by git URL instead: lex add github.com/user/{}",
            name, api, e, name
        ))
    });
    #[derive(Deserialize)]
    struct Entry {
        repo: String,
    }
    let parsed: Entry = serde_json::from_str(&body)
        .unwrap_or_else(|e| fail(&format!("malformed registry response for '{}': {}", name, e)));
    normalize_git_url(&parsed.repo)
}

/// Garante o índice do registry clonado em ~/.lex/registry (clona ou atualiza).
fn ensure_registry() -> PathBuf {
    let url = std::env::var("LEX_REGISTRY").unwrap_or_else(|_| DEFAULT_REGISTRY.to_string());
    let dir = lex_home().join("registry");
    let dir_str = dir.to_string_lossy().to_string();
    if dir.join(".git").is_dir() {
        // best-effort: atualiza; falha de rede não é fatal (usa o cache)
        let _ = git(&["-C", &dir_str, "pull", "--quiet", "--ff-only"]);
    } else {
        if let Some(parent) = dir.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        git(&["clone", "--depth", "1", "--quiet", &url, &dir_str]).unwrap_or_else(|e| {
            fail(&format!("failed to fetch the registry index from {}: {}", url, e))
        });
    }
    dir
}

// ===========================================================================
// registry — manutenção de um índice de pacotes (lado do mantenedor)
// ===========================================================================

/// `lex registry <init|add>` — cria e mantém um índice de registry (o repo git
/// que `lex add <nome>` consulta). Um índice é só uma pasta com
/// `packages/<nome>.toml` contendo `repo = "<url-git>"`, versionada com git.
fn cmd_registry(args: &[String]) {
    match args.first().map(|s| s.as_str()).unwrap_or("") {
        "init" => registry_init(args.get(1).map(|s| s.as_str()).unwrap_or(".")),
        "add" => {
            if args.len() < 3 {
                fail("usage: lex registry add <name> <repo-url> [index-dir]");
            }
            registry_add(&args[1], &args[2], args.get(3).map(|s| s.as_str()).unwrap_or("."));
        }
        _ => fail(
            "usage: lex registry <command>\n  \
             init [dir]                    scaffold a registry index repo\n  \
             add <name> <repo-url> [dir]   add or update a package entry",
        ),
    }
}

/// Cria a estrutura de um índice de registry em `dir` e inicializa o git.
fn registry_init(dir: &str) {
    let root = Path::new(dir);
    let packages = root.join("packages");
    if packages.is_dir() {
        fail(&format!("'{}' already looks like a registry (packages/ exists)", dir));
    }
    std::fs::create_dir_all(&packages)
        .unwrap_or_else(|e| fail(&format!("could not create {}: {}", packages.display(), e)));
    let readme = "# lex registry\n\n\
        Índice de pacotes do lex. Cada pacote é um arquivo `packages/<nome>.toml`:\n\n\
        ```toml\n# packages/cores.toml\nrepo = \"https://github.com/usuario/cores\"\n```\n\n\
        O `repo` aponta para um repositório git com um `lex.toml` na raiz; as\n\
        versões são as tags git (semver). Use `lex registry add <nome> <url>`\n\
        para adicionar entradas e versione com git. Quem consome aponta o\n\
        `LEX_REGISTRY` para a URL deste repo (o padrão é lex-language/registry).\n";
    std::fs::write(root.join("README.md"), readme).ok();
    if !root.join(".git").is_dir() {
        let ds = root.to_string_lossy().to_string();
        let _ = git(&["init", "--quiet", &ds]);
    }
    println!(
        "{}",
        diag::ok_line(&format!("registry index scaffolded in {}/", dir))
    );
}

/// Adiciona/atualiza `packages/<name>.toml` no índice em `dir`.
fn registry_add(name: &str, url: &str, dir: &str) {
    let packages = Path::new(dir).join("packages");
    if !packages.is_dir() {
        fail(&format!(
            "'{}' is not a registry index (no packages/) — run 'lex registry init' first",
            dir
        ));
    }
    let normalized = normalize_git_url(url);
    let entry = packages.join(format!("{}.toml", name));
    let existed = entry.exists();
    std::fs::write(&entry, format!("repo = \"{}\"\n", normalized))
        .unwrap_or_else(|e| fail(&format!("could not write {}: {}", entry.display(), e)));
    let verb = if existed { "updated" } else { "added" };
    println!(
        "{}",
        diag::ok_line(&format!("{} {} -> {}", verb, name, normalized))
    );
}

/// `lex publish [repo-url]` — imprime a entrada de registry para este pacote,
/// pronta para `lex registry add` (ou para colar no índice). Não faz rede.
fn cmd_publish(args: &[String]) {
    let m = load_manifest();
    let url = args
        .first()
        .cloned()
        .or_else(|| git_capture(&["remote", "get-url", "origin"]).ok())
        .map(|u| normalize_git_url(u.trim()))
        .unwrap_or_else(|| {
            fail("no repo URL: pass it (lex publish <url>) or set a git 'origin' remote")
        });

    // registry como SITE: faz POST do pacote para a API (em lex). O token, se
    // o servidor exigir, vem de LEX_REGISTRY_TOKEN.
    if let Some(api) = registry_api() {
        let mut obj = serde_json::json!({
            "name": m.package.name,
            "version": m.package.version,
            "repo": url,
            "description": m.package.description.clone().unwrap_or_default(),
        });
        if let Ok(tok) = std::env::var("LEX_REGISTRY_TOKEN") {
            if !tok.trim().is_empty() {
                obj["token"] = serde_json::Value::String(tok);
            }
        }
        let endpoint = format!("{}/api/publish", api);
        curl_post_json(&endpoint, &obj.to_string())
            .unwrap_or_else(|e| fail(&format!("publish failed: {}", e)));
        println!(
            "{}",
            diag::ok_line(&format!(
                "published {} {} to {}",
                m.package.name, m.package.version, api
            ))
        );
        return;
    }

    // sem API configurada: imprime a entrada para colar/adicionar no índice git.
    println!("# packages/{}.toml", m.package.name);
    println!("repo = \"{}\"", url);
    eprintln!(
        "{}",
        diag::ok_line(&format!(
            "add this to your registry index: lex registry add {} {}",
            m.package.name, url
        ))
    );
}

/// ~/.lex — cache global do lex (hoje só o índice do registry).
fn lex_home() -> PathBuf {
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .unwrap_or_else(|_| fail("could not determine the home directory (set HOME)"));
    PathBuf::from(home).join(".lex")
}

// ===========================================================================
// Git (a única dependência de rede)
// ===========================================================================

/// Roda `git <args>` silenciosamente; Ok(()) se status 0.
fn git(args: &[&str]) -> Result<(), String> {
    let status = Command::new("git")
        .args(args)
        .status()
        .map_err(|e| format!("could not run git ({}). is git installed?", e))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("git {} exited with {}", args.first().unwrap_or(&""), status))
    }
}

/// Roda `git <args>` e captura o stdout.
fn git_capture(args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .args(args)
        .output()
        .map_err(|e| format!("could not run git ({}). is git installed?", e))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).to_string())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).to_string())
    }
}

/// Lista as tags do repo remoto SEM clonar, como (versão semver, tag original).
/// Tags fora do padrão semver são ignoradas.
fn git_ls_tags(url: &str) -> Vec<(Version, String)> {
    let out = match git_capture(&["ls-remote", "--tags", "--refs", url]) {
        Ok(s) => s,
        Err(e) => fail(&format!("failed to list versions from {}: {}", url, e)),
    };
    let mut versions = Vec::new();
    for line in out.lines() {
        // formato: "<sha>\trefs/tags/<tag>"
        let Some(tag) = line.split("refs/tags/").nth(1) else { continue };
        let tag = tag.trim();
        let v = tag.strip_prefix('v').unwrap_or(tag);
        if let Ok(ver) = Version::parse(v) {
            versions.push((ver, tag.to_string()));
        }
    }
    versions
}

/// Escolhe a maior versão que satisfaz a restrição.
fn pick_version(versions: &[(Version, String)], req: &VersionReq) -> Option<(Version, String)> {
    versions
        .iter()
        .filter(|(v, _)| req.matches(v))
        .max_by(|(a, _), (b, _)| a.cmp(b))
        .cloned()
}

// ===========================================================================
// Leitura do manifesto de um pacote já baixado
// ===========================================================================

/// Lê o lex.toml dentro de `dir`, se houver.
fn read_pkg_manifest(dir: &Path) -> Option<Manifest> {
    let text = std::fs::read_to_string(dir.join(MANIFEST)).ok()?;
    toml::from_str(&text).ok()
}

fn read_pkg_version(dir: &Path) -> Option<String> {
    read_pkg_manifest(dir).map(|m| m.package.version)
}

fn read_pkg_deps(dir: &Path) -> BTreeMap<String, String> {
    read_pkg_manifest(dir).map(|m| m.dependencies).unwrap_or_default()
}

fn read_pkg_dep_names(dir: &Path) -> Vec<String> {
    read_pkg_deps(dir).into_keys().collect()
}

/// Ponto de entrada de um pacote instalado: o `main` do seu lex.toml. Usado
/// pelo resolvedor de módulos do compilador (em main.rs).
pub fn package_main(dir: &Path) -> Option<String> {
    read_pkg_manifest(dir).and_then(|m| m.package.main)
}

// ===========================================================================
// I/O do manifesto e do lock
// ===========================================================================

fn load_manifest() -> Manifest {
    let text = std::fs::read_to_string(MANIFEST).unwrap_or_else(|_| {
        fail(&format!("no {} here — run `lex init` first", MANIFEST))
    });
    toml::from_str(&text).unwrap_or_else(|e| fail(&format!("malformed {}: {}", MANIFEST, e)))
}

fn save_manifest(m: &Manifest) {
    let text = toml::to_string_pretty(m)
        .unwrap_or_else(|e| fail(&format!("could not serialize {}: {}", MANIFEST, e)));
    std::fs::write(MANIFEST, text)
        .unwrap_or_else(|e| fail(&format!("could not write {}: {}", MANIFEST, e)));
}

fn load_lock() -> Lockfile {
    match std::fs::read_to_string(LOCKFILE) {
        Ok(text) => toml::from_str(&text)
            .unwrap_or_else(|e| fail(&format!("malformed {}: {}", LOCKFILE, e))),
        Err(_) => Lockfile::default(),
    }
}

fn save_lock(lock: &Lockfile) {
    let text = toml::to_string_pretty(lock)
        .unwrap_or_else(|e| fail(&format!("could not serialize {}: {}", LOCKFILE, e)));
    std::fs::write(LOCKFILE, text)
        .unwrap_or_else(|e| fail(&format!("could not write {}: {}", LOCKFILE, e)));
}

// ===========================================================================
// Utilitários de filesystem
// ===========================================================================

/// Remove um arquivo ou diretório (recursivo), ignorando "não existe".
fn wipe(p: &Path) {
    if p.is_dir() {
        let _ = std::fs::remove_dir_all(p);
    } else if p.exists() {
        let _ = std::fs::remove_file(p);
    }
}

/// Copia uma árvore de diretórios, pulando .git e lex_modules aninhados.
fn copy_dir(src: &Path, dst: &Path) {
    std::fs::create_dir_all(dst)
        .unwrap_or_else(|e| fail(&format!("could not create {}: {}", dst.display(), e)));
    let entries = std::fs::read_dir(src)
        .unwrap_or_else(|e| fail(&format!("could not read {}: {}", src.display(), e)));
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name_s = name.to_string_lossy();
        if name_s == ".git" || name_s == MODULES_DIR {
            continue;
        }
        let from = entry.path();
        let to = dst.join(&name);
        if from.is_dir() {
            copy_dir(&from, &to);
        } else {
            std::fs::copy(&from, &to)
                .unwrap_or_else(|e| fail(&format!("could not copy {}: {}", from.display(), e)));
        }
    }
}

/// Erro fatal do gerenciador de pacotes (mesma cara dos erros do compilador).
fn fail(msg: &str) -> ! {
    diag::fatal_plain(msg)
}
