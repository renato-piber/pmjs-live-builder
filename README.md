# PMJS Live Builder

O PMJS Live Builder gera, de forma declarativa, uma nova ISO Debian Live para o
ecossistema PMJS. O projeto (configuracao, listas de pacotes, includes e hooks) e
a fonte da verdade; a ISO em `output/` e um artefato descartavel. Nao ha
remasterizacao incremental de uma ISO anterior e nenhum `/home` do HOST e copiado.

## Escopo da Sprint 1

A imagem e `amd64`, usa o usuario Live `usuario`, hostname `pmjs-live`, sessao
grafica MATE, terminal, NetworkManager, NFS, ferramentas de disco/imagem e zstd.
O `live-build` gera uma ISO hibrida com GRUB para UEFI e Legacy BIOS. Secure Boot
fica em modo `auto`: a disponibilidade de binarios assinados e validada durante o
build, mas nao e uma garantia desta Sprint.

Branding, Plymouth, wallpaper, launcher, menu PMJS, autostart e a incorporacao
real de PMJS Deploy/Image Builder ficaram deliberadamente fora desta Sprint.

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
sudo apt install live-build debootstrap xorriso squashfs-tools curl ca-certificates
```

O build requer root, pelo menos 20 GiB livres (ajustavel em `config/live.conf`) e
acesso HTTPS aos repositorios Debian. No HOST inspecionado ha cerca de 59,6 GiB
livres, mas `live-build`, `lb`, `debootstrap` e `xorriso` nao estao instalados.

Internet e necessaria no computador que **constroi** a imagem para baixar os
pacotes. Depois de pronta, a ISO contem o sistema e as ferramentas listadas e
pode iniciar e operar localmente sem Internet. Naturalmente, funcoes que acessam
servicos remotos continuam dependendo de rede.

## Construir

```bash
sudo ./build-live.sh
```

Fluxo: preflight, limpeza protegida de `work/`, `lb config`, aplicacao da
configuracao versionada, `lb build`, smoke test estrutural, publicacao atomica e
SHA-256. A saida completa do `live-build` aparece no terminal e fica em `logs/`.
Somente uma ISO validada e copiada para:

```text
output/pmjs-live-0.1.0-amd64.iso
output/SHA256SUMS
```

Para executar apenas o preflight:

```bash
sudo ./build-live.sh --preflight
```

## Limpar

```bash
sudo ./build-live.sh --clean
```

O clean atua somente sob o `work/` validado, recusa a raiz do projeto, caminhos
externos, links simbolicos e areas com mounts ativos. `output/` e `logs/` sao
preservados.

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
./build-live.sh --smoke-test output/pmjs-live-0.1.0-amd64.iso
```

Ele verifica o SquashFS e registros El Torito BIOS/UEFI; nao prova que a imagem
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

Firmware comum Intel, Realtek, Atheros e Broadcom foi incluido pela area Debian
`non-free-firmware` para melhorar a chance de rede em hardware real. Nenhuma
credencial, senha real, chave SSH ou configuracao NFS e incorporada.

## PMJS Deploy e Image Builder

`config-live/includes.chroot/opt/pmjs/` e o ponto versionado de inclusao. O hook
cria `/opt/pmjs/deploy` e `/opt/pmjs/image-builder`, mas esta Sprint nao inventa
executaveis nem copia diretorios externos. Quando os projetos reais forem
fornecidos de forma explicita, seus arquivos e launchers `pmjs-deploy` e
`pmjs-image-builder` poderao ser adicionados ali em uma Sprint posterior.

## Nota sobre reproducibilidade

O procedimento e reexecutavel a partir do repositorio, com codinome, arquitetura
e selecao de pacotes declarados. Como os mirrors `trixie` recebem atualizacoes,
builds em datas diferentes podem conter versoes de pacotes diferentes. Se houver
exigencia futura de reproducibilidade byte a byte, o proximo incremento deve fixar
um snapshot Debian, versoes e `SOURCE_DATE_EPOCH`.

