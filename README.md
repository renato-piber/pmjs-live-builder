# PMJS Live Builder

O PMJS Live Builder gera, de forma declarativa, uma nova ISO Debian Live para o
ecossistema PMJS. O projeto (configuracao, listas de pacotes, includes e hooks) e
a fonte da verdade; a ISO em `output/` e um artefato descartavel. Nao ha
remasterizacao incremental de uma ISO anterior e nenhum `/home` do HOST e copiado.

## Escopo atual

A imagem e `amd64`, usa o usuario Live `usuario`, hostname `pmjs-live`, sessao
grafica MATE, terminal, NetworkManager, NFS, Python 3, ferramentas de
disco/imagem e zstd. A Fase 4 incorpora snapshots runtime controlados do PMJS
Deploy e PMJS Image Builder, wrappers de terminal, launchers MATE, branding
institucional e uma baseline explicita de firmware para hardware real.
O `live-build` gera uma ISO hibrida com GRUB para UEFI e Legacy BIOS. Secure Boot
fica em modo `auto`: a disponibilidade de binarios assinados e validada durante o
build, mas nao e uma garantia desta Sprint.

Plymouth, navegador e autostart nao fazem parte desta fase. O fluxo de build,
LightDM, Xorg, kernel e boot nao recebeu contornos especificos para hardware.

## Suite Debian

`config/live.conf` fixa o codinome `trixie` (Debian 13), a versao stable atual na
criacao deste projeto. Usar o codinome evita que um alias movel como `stable`
mude silenciosamente a base. `bookworm` ainda e uma alternativa oldstable com
suporte, mas nao foi escolhida para uma imagem nova; `forky` (testing) e `sid`
(unstable) oferecem menor previsibilidade operacional.

O HOST detectado durante esta implementacao e Debian 12 `bookworm`. O build entre
suites pode funcionar, mas a opcao recomendada e executar o Builder em Debian 13
`trixie` (maquina fisica ou VM), usando as versoes correspondentes de
`live-build` e `debootstrap`. O preflight registra e avisa quando HOST e alvo
diferem.

Suites e repositorios evoluem. Antes de uma futura release do PMJS Live, revise
explicitamente `DEBIAN_SUITE`; o preflight tambem exige que os arquivos `Release`
principal e de seguranca existam e estejam acessiveis.

## Dependencias do HOST

Em um HOST Debian 13:

```bash
sudo apt update
sudo apt install live-build debootstrap xorriso squashfs-tools curl ca-certificates desktop-file-utils file
```

O build requer root, pelo menos 20 GiB livres (ajustavel em `config/live.conf`) e
acesso HTTPS aos repositorios Debian. O preflight verifica as ferramentas antes
de alterar o estado de build.

Internet e necessaria no computador que **constroi** a imagem para baixar os
pacotes. Depois de pronta, a ISO contem o sistema e as ferramentas listadas e
pode iniciar e operar localmente sem Internet. Naturalmente, funcoes que acessam
servicos remotos continuam dependendo de rede.

## Construir

```bash
sudo ./build-live.sh
```

Fluxo: preflight, preparacao protegida de `work/`, conexao do cache persistente,
`lb config`, aplicacao da configuracao versionada, `lb build`, smoke test
estrutural, validacao dos executaveis, publicacao atomica e SHA-256. A saida
completa do `live-build` aparece no terminal e fica em `logs/`.
Somente uma ISO validada e copiada para:

```text
output/pmjs-live-0.1.1-amd64.iso
output/SHA256SUMS
```

Para executar apenas o preflight:

```bash
sudo ./build-live.sh --preflight
```

## Cache persistente e limpeza

O cache fica em `cache/`, separado do estado descartavel em `work/`. O Builder
usa os mecanismos nativos `--cache` e `--cache-packages` do `live-build`; durante
o build, `work/cache` e apenas um symlink validado para esse diretorio. Nao ha
copia de `/var/cache/apt` do HOST.

Indices APT nao sao cacheados. O build normal pode reutilizar tanto os downloads
`.deb` quanto o snapshot nativo do estagio `bootstrap`; ainda assim, cada build
consulta metadados atuais e o APT verifica assinaturas e hashes, baixando pacotes
ausentes ou atualizados.

Build normal, reutilizando e preservando o cache:

```bash
sudo ./build-live.sh
```

Limpar apenas o estado descartavel:

```bash
sudo ./build-live.sh --clean
```

Apagar estado e cache, equivalendo a uma primeira construcao quanto a downloads:

```bash
sudo ./build-live.sh --purge
```

`--clean` remove tambem snapshots de estagio (`bootstrap`, `chroot` e `rootfs`),
mas preserva `cache/packages.*` e outros metadados/downloads que nao sejam
snapshots; `--purge` esvazia todo `cache/`. Ambos validam os caminhos,
recusam a raiz do projeto, caminhos externos, links simbolicos, caches ambíguos e
areas com mounts ativos. `output/` e `logs/` sao preservados.

Se um cache nativo antigo ainda existir em `work/cache`, o primeiro comando o
migra por rename para `cache/`. Se ambos os locais contiverem dados, a mesclagem
automatica e recusada para evitar perda silenciosa.

Inspecao do cache:

```bash
du -sh cache
find cache -type f -name '*.deb' | wc -l
```

## Verificar e testar

Checksum:

```bash
cd output
sha256sum --check SHA256SUMS
```

Testes rapidos, sem construir ISO nem baixar pacotes:

```bash
./tests/run.sh
```

Smoke test de uma ISO existente:

```bash
./build-live.sh --smoke-test output/pmjs-live-0.1.1-amd64.iso
```

Durante um build, o Builder tambem inspeciona o SquashFS intermediario com
`unsquashfs -ll` e exige ferramentas auditadas, aplicativos PMJS, launchers,
assets e firmware Renoir, sem montar ou extrair a imagem. O smoke test da ISO verifica o
SquashFS e registros El Torito BIOS/UEFI; nenhum desses testes prova que a imagem
inicia em todo firmware. Para Ventoy, instale o Ventoy em um pendrive por seu
procedimento oficial, copie a ISO e selecione-a no menu de boot. Teste depois em:

1. UEFI com Secure Boot desativado inicialmente;
2. Legacy BIOS/CSM;
3. hardware real com rede cabeada, Wi-Fi, terminal, NFS e discos de teste.

Registre os resultados: estes cenarios nao foram alegados como testados
automaticamente nesta Sprint.

## MATE e pacotes

Foi usado `mate-desktop-environment-core`, que traz os componentes essenciais da
sessao (Marco, painel, configuracoes e Caja), acompanhado explicitamente de Xorg,
LightDM, terminal e integracao do NetworkManager. `--apt-recommends false` evita a
colecao ampla de aplicativos sugeridos; as dependencias necessarias sao listadas
explicitamente por categoria em `config-live/package-lists/`.

Firmware de grafico AMD/Intel e de rede Intel, Realtek, Atheros, Broadcom e
MediaTek foi incluido pela area Debian `non-free-firmware`; a baseline tambem
inclui o pequeno pacote DFSG `firmware-linux-free`. A receita exige
explicitamente os blobs AMD Renoir que faltavam no boot real. Nenhuma credencial,
senha real ou chave SSH e incorporada; as configuracoes operacionais dos
aplicativos fazem parte de seus snapshots runtime.

## Dependencias de runtime PMJS

As listas declaram explicitamente os pacotes que fornecem as ferramentas
esperadas pelo PMJS Deploy e PMJS Image Builder:

| Executaveis | Pacote Debian |
|---|---|
| `python3` | `python3` |
| `bash` | `bash` |
| `tar` | `tar` |
| `gzip` | `gzip` |
| `zstd` | `zstd` |
| `rsync` | `rsync` |
| `sha256sum`, `chroot` | `coreutils` |
| `btrfs` | `btrfs-progs` |
| `lsblk`, `blkid`, `findmnt`, `mkswap` | `util-linux` |
| `mount`, `umount`, `swapon`, `swapoff` | `mount` |
| `parted` | `parted` |
| `mkfs.vfat` | `dosfstools` |
| `grub-install`, `update-grub` | `grub2-common` |
| modulos GRUB BIOS/UEFI | `grub-pc-bin`, `grub-efi-amd64-bin` |
| `ssh-keygen` | `openssh-client` |
| `mount.nfs` | `nfs-common` |
| `curl`, `wget` | `curl`, `wget` |
| `ip`, `ping` | `iproute2`, `iputils-ping` |
| `smartctl` | `smartmontools` |
| `nvme` | `nvme-cli` |
| `testdisk` | `testdisk` |
| `ddrescue` | `gddrescue` |
| `jq` | `jq` |
| `pluma`, `filezilla`, `gparted`, `gnome-disks` | `pluma`, `filezilla`, `gparted`, `gnome-disk-utility` |

No Sprint 1.1 foram acrescentados diretamente `python3`, `mount`,
`grub2-common` e `openssh-client`; os demais ja estavam declarados. Isso evita
depender de instalacoes indiretas que podem mudar com o grafo de dependencias.

## PMJS Deploy e Image Builder

`config-live/includes.chroot/opt/pmjs/` contem snapshots runtime versionados, nao
checkouts completos. A ISO e construida somente a partir desta arvore e continua
independente da presenca dos projetos irmaos e de `../images`.

Antes de construir uma release, atualize os snapshots deliberadamente:

```bash
./tools/update-pmjs-snapshots.sh
```

O atualizador possui uma lista fechada de entrypoints, configuracoes, assets e
bibliotecas necessarias; grava versao/commit em `SNAPSHOT`, valida em staging e
troca por rename. Testes, `.git`, logs, caches, workdirs e imagens grandes nao
entram. Consulte `docs/PHASE4_INTEGRATION.md` para a auditoria completa e o modo
de informar checkouts em outros caminhos.

Na Live, execute `pmjs-deploy` ou `pmjs-image-builder` de qualquer diretorio. Os
wrappers chamam `/opt/pmjs/...` por caminho absoluto, abrem em terminal pelos
launchers do MATE e usam o `sudo` normal quando necessitam privilegios. Nao ha
regra `NOPASSWD` ou wrapper com logica de negocio duplicada.

Os launchers aparecem no menu MATE e na Area de Trabalho. Icones e wallpaper
foram copiados para a propria receita Live; nenhum path externo e necessario no
build.

## Nota sobre reproducibilidade

O procedimento e reexecutavel a partir do repositorio, com codinome, arquitetura
e selecao de pacotes declarados. Como os mirrors `trixie` recebem atualizacoes,
builds em datas diferentes podem conter versoes de pacotes diferentes. Se houver
exigencia futura de reproducibilidade byte a byte, o proximo incremento deve fixar
um snapshot Debian, versoes e `SOURCE_DATE_EPOCH`.

Releases oficiais devem partir de estado descartavel limpo (`--clean`). O cache
de pacotes pode ser mantido: ele nao fixa versoes, e o APT ainda valida os `.deb`
contra os metadados atuais. Para medir o ganho, compare dois builds consecutivos
da mesma receita e mirror: primeiro apos `--purge` (cache frio), depois um build
normal (cache quente). Use as duracoes registradas no fim dos logs ou
`/usr/bin/time -p`; tamanho e quantidade de `.deb` tambem sao registrados. O
Builder nao declara “bytes reutilizados”, pois o `live-build` nao fornece essa
metrica de forma confiavel.
