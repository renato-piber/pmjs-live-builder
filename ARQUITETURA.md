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
        +-- futuro: PMJS Deploy
        `-- futuro: PMJS Image Builder
```

O Builder nunca usa a ISO anterior como entrada. A cada execucao ele cria uma
configuracao limpa em `work/`, baixa a base Debian e monta novamente o filesystem
Live. Isso elimina o estado oculto tipico de remasterizacoes incrementais.

## Componentes

- `config/live.conf`: nome, versao, arquitetura, identidade Live, suite, mirrors
  e diretorios. E a configuracao central do projeto.
- `config-live/package-lists/*.list.chroot`: pacotes instalados no filesystem
  Live, separados por responsabilidade.
- `config-live/includes.chroot/`: arquivos copiados para a raiz da Live. A arvore
  `/opt/pmjs` esta reservada para componentes reais fornecidos futuramente.
- `config-live/hooks/live/*.hook.chroot`: operacoes que precisam ocorrer dentro
  do chroot depois da instalacao dos pacotes.
- `lib/checks.sh`: parsing, validacao, deteccao do HOST, dependencias, espaco e
  acesso aos repositorios.
- `lib/build.sh`: workdir, chamada direta ao `live-build`, validacao e publicacao.
- `lib/logs.sh` e `lib/ui.sh`: log iniciado antes do preflight e mensagens.
- `tests/run.sh`: testes locais sem bootstrap Debian nem construcao integral.

## Pipeline e fronteiras

```text
inicio do log
   -> carregar/validar config
   -> preflight (root, HOST, ferramentas, espaco, repositorios)
   -> limpar work/ com guardas
   -> lb config em work/
   -> copiar config-live/ para work/config/
   -> lb build
   -> validar ISO e boot records
   -> copiar atomicamente para output/
   -> gerar SHA256SUMS e resumo no log
```

`work/` e descartavel e pode conter chroot, caches e produto intermediario.
`output/` recebe somente a ISO depois de um build e smoke test bem-sucedidos.
Falhas de preflight tambem sao gravadas em `logs/`; a saida do `live-build` nao e
suprimida.

## Boot e sessao Live

`lb config` solicita `iso-hybrid` e os bootloaders `grub-pc` e `grub-efi`. Os
parametros de boot entregues ao `live-config` definem `usuario`, `pmjs-live`,
locale pt_BR e teclado brasileiro. LightDM inicia a sessao grafica MATE e o hook
habilita LightDM/NetworkManager, sem branding ou autostart PMJS.

O smoke test confirma que a estrutura produzida declara entradas El Torito para
BIOS e UEFI e contem `/live/filesystem.squashfs`. Validacao definitiva exige boot
em VM e em hardware UEFI/Legacy.

## Seguranca e dados externos

Somente arquivos dentro de `config-live/includes.chroot` entram por include. Nao
ha varredura de `/home`, importacao automatica de outros repositorios nem leitura
de credenciais. O clean resolve e valida seu alvo e recusa symlinks, caminhos fora
de `work/` e diretorios com mounts ativos.

