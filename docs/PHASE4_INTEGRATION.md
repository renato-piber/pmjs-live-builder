# Fase 4: integracao final da PMJS Live

## Resultado da auditoria

A integracao foi feita somente no PMJS Live Builder. Os repositorios do PMJS
Deploy e do PMJS Image Builder foram lidos para identificar seus entrypoints,
configuracoes e dependencias runtime; nenhum arquivo deles e alterado durante o
build da Live.

O Deploy inicia em `deploy.sh`, carrega `config/deploy.conf` e as bibliotecas de
`lib/`. O Image Builder inicia em `build-image.sh`; `publish-image.sh` e
`sync-image-to-ventoy.sh` sao operacoes runtime adicionais. Copiar os checkouts
inteiros levaria testes, documentacao, historico Git e possiveis artefatos para a
ISO. Por isso a Live mantem snapshots explicitamente enumerados.

## Snapshots controlados

Execute, na raiz deste projeto:

```bash
./tools/update-pmjs-snapshots.sh
```

Por padrao, a ferramenta le `../pmjs-deploy` e `../pmjs-image-builder`. Checkouts
em outros locais podem ser informados explicitamente:

```bash
./tools/update-pmjs-snapshots.sh \
  --deploy-source /caminho/pmjs-deploy \
  --image-builder-source /caminho/pmjs-image-builder
```

O script exige todos os arquivos runtime de sua lista fechada, copia-os para um
staging oculto dentro de `config-live/includes.chroot/opt/pmjs/`, valida o
resultado e troca cada snapshot por rename. Se a troca falhar, restaura a versao
anterior; um staging que nao puder ser restaurado com seguranca e preservado para
diagnostico. A ferramenta nunca usa `rm -rf`.

Entram no snapshot do Deploy: `VERSION`, `deploy.sh`, `config/deploy.conf`, o
helper `assets/auto-mirror-x11` e as bibliotecas efetivamente carregadas. Entram
no snapshot do Image Builder: `VERSION`, os tres entrypoints, `config/image.conf`
e suas bibliotecas runtime. Cada snapshot ganha um arquivo `SNAPSHOT` com nome,
versao, commit e estado dos arquivos copiados.

Ficam explicitamente de fora: `.git`, testes, documentacao de desenvolvimento,
logs, caches, `work`, `output`, bundles `pmjs-linux-*`, `rootfs.tar.*`,
`homefs.tar.*` e arquivos parciais. O preflight recusa esses nomes e qualquer
arquivo com mais de 20 MiB dentro dos snapshots.

O build da ISO consome somente o conteudo ja versionado em
`config-live/includes.chroot`; ele nao depende de diretorios irmaos nem de
`../images`.

## Execucao e privilegios

Na Live, os comandos publicos sao:

```text
/usr/local/bin/pmjs-deploy
/usr/local/bin/pmjs-image-builder
```

Os wrappers usam caminhos absolutos para os entrypoints em `/opt/pmjs`, portanto
funcionam a partir de qualquer diretorio. Se a sessao ja for root, usam `exec`
direto; caso contrario, usam `exec sudo -- ...`. Assim, o terminal exibe a
autenticacao normal, os argumentos e o codigo de saida sao preservados e nao ha
regra `NOPASSWD`, setuid ou politica paralela de privilegios.

Os launchers em `/usr/share/applications` aparecem no menu MATE, usam nomes de
icone instalados e abrem um terminal. Os atalhos em `/etc/skel/Desktop` sao links
para esses launchers de sistema, executaveis e controlados por root. Isso evita
depender do atributo de confianca gravado por usuario via `gio`. A aceitacao
visual ainda deve ser confirmada em um boot real, pois a apresentacao de atalhos
pode variar com a versao do Caja/MATE.

## Branding

Os dois PNG de aplicativo e o wallpaper selecionado foram copiados para dentro
deste repositorio, sem conversao:

```text
/usr/share/pixmaps/pmjs-deploy.png
/usr/share/pixmaps/pmjs-image-builder.png
/usr/share/backgrounds/pmjs/pmjs-wallpaper.jpg
```

Os PNG originais nao possuem dimensoes padrao de tema, portanto
`/usr/share/pixmaps` e o local apropriado. Os launchers referenciam os nomes
`pmjs-deploy` e `pmjs-image-builder`, nunca caminhos externos. O wallpaper
institucional 1920x1080 selecionado e aplicado como padrao de
`org.mate.background` por um override GSettings; o usuario pode altera-lo.

## Firmware e ferramentas

A falha AMD Renoir era objetiva: os arquivos `amdgpu/renoir_*.bin` nao estavam
na receita anterior. No Debian 13, eles sao fornecidos por
`firmware-amd-graphics`. O pacote foi adicionado e a validacao pos-build exige
cinco blobs Renoir especificos. `firmware-intel-graphics` cobre a baseline
grafica Intel. O pequeno `firmware-linux-free` cobre blobs DFSG de outros
drivers do kernel. Tambem entram microcodigos AMD/Intel.

Para rede, a selecao permanece explicita: Intel Wi-Fi, Realtek, Atheros,
Broadcom, MediaTek, Intel misc e Broadcom NetXtreme (`bnx2`). Nao foi usado um
metapacote indiscriminado de todo firmware, nem foram adicionados drivers
proprietarios NVIDIA.

Referencias oficiais Debian 13:

- <https://packages.debian.org/trixie/firmware-amd-graphics>
- <https://packages.debian.org/trixie/all/firmware-amd-graphics/filelist>
- <https://packages.debian.org/trixie/firmware-intel-graphics>
- <https://packages.debian.org/trixie/firmware-linux-free>
- <https://packages.debian.org/trixie/firmware-intel-misc>
- <https://packages.debian.org/trixie/firmware-realtek>
- <https://packages.debian.org/trixie/firmware-bnx2>

As ferramentas solicitadas estao declaradas diretamente: Python 3, zstd,
cliente NFS, Pluma, FileZilla, GParted, Discos do GNOME, smartmontools, nvme-cli,
testdisk, gddrescue, rsync, curl, wget e jq. As dependencias observadas nos dois
aplicativos tambem incluem ferramentas GNU basicas, tar/gzip, util-linux,
particionamento, filesystems, GRUB BIOS/UEFI, OpenSSH, rede e udev.

O Visual Studio Code e instalado como pacote `code` pelo repositorio oficial da
Microsoft. O feed, a chave publica auditada e o pinning de origem ficam
versionados em `config-live/archives/` e sao aplicados nativamente pelo
`live-build` nas fases chroot e binary. Isso torna o pacote resolvivel durante a
build e deixa o mesmo repositorio configurado na Live, sem alterar as fontes
Debian, executar scripts remotos ou exigir configuracao apos o boot.

Nenhuma alteracao foi feita no kernel, Xorg, LightDM ou fluxo de boot para
contornar firmware. LightDM e NetworkManager continuam apenas habilitados pelo
hook baseline existente.

## Validacao sem construir a ISO

```bash
./tests/run.sh
desktop-file-validate config-live/includes.chroot/usr/share/applications/*.desktop
git diff --check
```

Os testes verificam a lista exata dos snapshots, exclusoes, limites de tamanho,
permissoes, wrappers, launchers, links do Desktop, MIME dos assets, override do
wallpaper, repositorio/chave do Visual Studio Code, pacotes sem duplicidade e
receita/validacao Renoir. O build completo
continua sendo necessario antes de uma release para comprovar a resolucao APT,
o conteudo final do SquashFS e o boot em hardware.

## Riscos operacionais restantes

- O PMJS Deploy incorporado conserva sua configuracao de producao: tenta a fonte
  NFS e depois o diretorio offline definido pelo proprio Deploy. A Live Builder
  nao adiciona autodeteccao do volume Ventoy; isso deve ser validado no fluxo
  operacional ou evoluido no repositorio do Deploy em trabalho separado.
- A disponibilidade e o comportamento dos mirrors Debian mudam com o tempo. Um
  build real limpo e necessario para validar a selecao completa de pacotes.
- Menu, confianca do atalho e wallpaper precisam de smoke test visual em uma
  sessao MATE real.
- A presenca dos blobs Renoir no SquashFS e validada, mas o carregamento correto
  do firmware so pode ser confirmado no hardware afetado.
