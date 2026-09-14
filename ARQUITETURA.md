# Arquitetura do PMJS Live Builder

```text
PMJS Live Builder (fonte versionada)
        |
        v
Debian live-build + repositorios da suite trixie
        |
        v
PMJS Live ISO (artefato descartavel)
        |
        +-- /opt/pmjs/deploy (snapshot runtime)
        `-- /opt/pmjs/image-builder (snapshot runtime)
```

O Builder nunca usa a ISO anterior como entrada. A cada execucao ele cria uma
configuracao limpa em `work/`, baixa a base Debian e monta novamente o filesystem
Live. Isso elimina o estado oculto tipico de remasterizacoes incrementais.

## Componentes

- `config/live.conf`: nome, versao, arquitetura, identidade Live, suite, mirrors
  diretorios e politica de cache. E a configuracao central do projeto.
- `config-live/package-lists/*.list.chroot`: pacotes instalados no filesystem
  Live, separados por responsabilidade.
- `config-live/includes.chroot/`: aplicativos PMJS, wrappers, launchers e assets
  copiados para a raiz da Live sem depender de caminhos externos no build.
- `config-live/hooks/live/*.hook.chroot`: operacoes que precisam ocorrer dentro
  do chroot depois da instalacao dos pacotes.
- `lib/checks.sh`: parsing, validacao, deteccao do HOST, dependencias, espaco e
  acesso aos repositorios.
- `lib/build.sh`: workdir, chamada direta ao `live-build`, validacao e publicacao.
- `lib/logs.sh` e `lib/ui.sh`: log iniciado antes do preflight e mensagens.
- `tests/run.sh`: testes locais sem bootstrap Debian nem construcao integral.
- `tools/update-pmjs-snapshots.sh`: atualizacao atomica e enumerada dos snapshots
  runtime a partir dos dois repositorios de origem.

## Pipeline e fronteiras

```text
inicio do log
   -> carregar/validar config
   -> preflight (root, HOST, ferramentas, snapshots, assets, espaco, repositorios)
   -> migrar cache nativo legado, se necessario
   -> limpar work/ com guardas, preservando cache/
   -> conectar work/cache -> cache/
   -> lb config em work/
   -> copiar config-live/ para work/config/
   -> lb build
   -> validar ISO, boot records e executaveis no SquashFS
   -> copiar atomicamente para output/
   -> gerar SHA256SUMS e resumo no log
```

`work/` e descartavel e contem chroot e produto intermediario.
`cache/` persiste separadamente e contem os caches nativos de pacotes do
`live-build` (`packages.bootstrap`, `packages.chroot` e `packages.binary`). O
symlink `work/cache` existe apenas para integrar esse local persistente ao layout
esperado pelo `live-build`.

Indices APT nao persistem. No build normal, `CACHE_STAGES=bootstrap` permite
reutilizar o bootstrap nativo; `--clean` remove esse e qualquer outro snapshot de
estagio, preservando `packages.*` e outros dados de cache que nao sejam snapshots
para a proxima construcao. O cache reduz downloads sem substituir a resolucao e
validacao atual do APT.

`output/` recebe somente a ISO depois de um build e smoke test bem-sucedidos.
Falhas de preflight tambem sao gravadas em `logs/`; a saida do `live-build` nao e
suprimida.

## Boot e sessao Live

`lb config` solicita `iso-hybrid` e os bootloaders `grub-pc` e `grub-efi`. Os
parametros de boot entregues ao `live-config` definem `usuario`, `pmjs-live`,
locale pt_BR e teclado brasileiro. LightDM inicia a sessao grafica MATE e o hook
habilita LightDM/NetworkManager. Um override GSettings configura o wallpaper
institucional; launchers de sistema ficam no menu e, por links em `/etc/skel`,
na Area de Trabalho.

O smoke test confirma que a estrutura produzida declara entradas El Torito para
BIOS e UEFI e contem `/live/filesystem.squashfs`. Validacao definitiva exige boot
em VM e em hardware UEFI/Legacy.

Apos o build, `unsquashfs -ll` consulta somente os metadados do SquashFS
intermediario e confirma ferramentas criticas, snapshots, wrappers, launchers,
assets e os blobs AMD Renoir. Nao ha mount temporario a desmontar.

## Seguranca e dados externos

Somente arquivos dentro de `config-live/includes.chroot` entram por include. O
build nao varre `/home`, nao importa repositorios irmaos e nao le credenciais. A
atualizacao deliberada dos snapshots usa uma allowlist e registra versao/commit;
testes, `.git`, caches e bundles sao recusados. O clean resolve e valida seu alvo e recusa symlinks, caminhos fora
de `work/` e diretorios com mounts ativos. A mesma politica protege `cache/`.
`--clean` remove estado e snapshots, preservando downloads `.deb`; `--purge`
remove estado e todo o conteudo do cache, sem usar `rm -rf`.

Os wrappers publicos usam caminhos absolutos e `exec`; usam o processo atual
quando root ou a politica padrao de `sudo` quando nao root. Eles nao replicam
regras de negocio do Deploy ou do Image Builder. A lista de arquivos e as
decisoes de integracao estao detalhadas em `docs/PHASE4_INTEGRATION.md`.
