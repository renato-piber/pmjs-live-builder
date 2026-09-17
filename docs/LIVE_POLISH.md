# Auditoria e acabamento da PMJS Live

Revisao de 2026-09-17, exclusivamente no Live Builder. Nao houve commit, captura,
mount NFS, publicacao de imagem PMJS, instalacao no HOST ou build completo da ISO.
Os projetos Deploy/Image Builder e seus snapshots runtime foram preservados.

## Firefox ESR: proxy e credenciais

Nao havia policy de proxy nem homepage institucional nos includes versionados.
Foi acrescentado `/etc/firefox/policies/policies.json`, caminho Linux system-wide
[suportado pela Mozilla](https://support.mozilla.org/en-US/kb/customizing-firefox-using-policiesjson).
A policy `Proxy` usa modo manual, HTTP e HTTPS em `proxy.empresa.local:8080`,
`UseHTTPProxyForAllProtocols=true` e `AutoLogin=false`. O proxy e um default
institucional, nao bloqueado: o operador pode adapta-lo para outro ambiente.
Um perfil persistente que ja tenha preferencias de proxy pode prevalecer;
o caso de uso principal e o perfil novo do boot Live.

Nao ha usuario/senha, URL com credenciais ou banco de logins incorporado. A
autenticacao permanece interativa. `OfferToSaveLogins=false` impede o Firefox de
oferecer/gravar logins no gerenciador de senhas (vale tambem para sites, nao
apenas para o proxy). Credenciais digitadas podem existir em memoria durante a
sessao autenticada; nao sao dados da ISO. Homepage, DNS e NetworkManager nao
foram alterados. Verificar `about:policies` (Active/Errors) no proximo boot e
testar HTTP/HTTPS com a autenticacao real, sem colocar a senha em logs.

Referencias: [Proxy](https://firefox-admin-docs.mozilla.org/reference/policies/proxy/)
e [OfferToSaveLogins](https://firefox-admin-docs.mozilla.org/reference/policies/offertosavelogins/).

## Intel/AMD microcode: cadeia auditada e limites do diagnostico

Adicionar pacotes nao resolveria a investigacao: ambos ja estavam declarados.
O artefato existente `output/pmjs-live-0.1.2-amd64.iso` foi inspecionado sem boot
ou rebuild. Seu `/live/initrd.img-6.12.107+deb13-amd64` foi extraido somente para
um temporario da auditoria; SHA256:

```text
cc1aeede01ab9770a7957fc8d395917561197a3c08429fc468f8eb17b1b7a926
```

Esse hash coincide com o initrd intermediario em `work/binary/live/`. Seu CPIO
early ja contem `kernel/x86/microcode/GenuineIntel.bin`. A inspecao com o
`iucode_tool` do chroot encontrou sig `0x000306c3`, platform mask `0x32`, revisao
`0x28`, data 2019-11-12: atualizacao Haswell superior a `0x22`. O kernel tem
`CONFIG_MICROCODE=y`; os argumentos GRUB gerados nao desativam o loader. Os
pacotes do artefato sao Intel `3.20251111.1~deb13u1` e AMD `3.20250311.1`.

Portanto **nao foi demonstrada ausencia de Intel early microcode nesta ISO**.
A revisao `0x17` vista no i3-4160 nao pode ser explicada apenas pela receita ou
pela package-list. Ainda falta confirmar que esse foi exatamente o artefato
bootado, o cmdline efetivo, CPUID/platform e o comportamento do bootloader.
Nao se afirma que a falha Intel de hardware foi resolvida por esta revisao.

Foi comprovado um defeito de portabilidade: `AuthenticAMD.bin` estava ausente
do early CPIO. O hook Debian AMD em modo `auto` consulta a CPU do HOST e omite
o payload ao construir em Intel. O hook Intel com `MODULES=most` ja usava
early/sem scan; com outras configuracoes poderia selecionar apenas a CPU HOST.

Solucao justificada: includes `/etc/default/intel-microcode` com
`IUCODE_TOOL_INITRAMFS=early`, `IUCODE_TOOL_SCANCPUS=no`, sem filtros extras; e
`/etc/default/amd64-microcode` com `AMD64UCODE_INITRAMFS=early`.
Na versao instalada de live-build (`1:20230502`), a sequencia e:

```text
instalacao dos pacotes -> includes.chroot -> hooks.chroot
  -> chroot_hacks: update-initramfs -k all -t -u
  -> initrd em binary/live -> ISO -> validacoes -> publicacao
```

Nao foi criado hook duplicado de regeneracao. Os defaults chegam antes da
regeneracao final; kernel, firmware grafico Renoir e GRUB continuam intactos.
Se outra versao de live-build mudar a sequencia, a validacao bloqueia a
publicacao em caso de payloads ausentes.

`tools/validate-early-microcode.py` exige payloads Intel/AMD nao vazios em CPIOs
nao comprimidos **antes** do initrd principal; suporta varios CPIOs concatenados
com padding. Verifica estrutura/checksum das atualizacoes Intel e presenca da
atualizacao Haswell `0x306c3` >= `0x22`. Nao procura firmware dentro do initrd
comprimido, nao extrai arquivos e nao aplica microcode ao HOST. O build valida
cada initrd intermediario antes de publicar. A ferramenta testa presenca AMD,
nao compatibilidade de cada CPU AMD nem aplicacao real pelo processador.

O initrd da ISO anterior falha nessa nova validacao por ausencia de AMD, como
esperado. Fixtures com Intel/AMD early passam. A proxima ISO ainda precisa ser
construida/testada pelo operador para comprovar a nova inclusao real.

Coleta recomendada no proximo boot Intel (nao executada nesta rodada):

```bash
cat /proc/cmdline
lscpu
grep -E 'vendor_id|cpu family|model|stepping|microcode' /proc/cpuinfo
sudo dmesg | grep -Ei 'microcode|TSC_DEADLINE|MDS|SRBDS'
```

Compare tambem o SHA256 da ISO copiada ao Ventoy com `output/SHA256SUMS`.
Se persistir, comparar boot direto USB e os modos de boot Ventoy, sem alterar
kernel/GRUB silenciosamente. Uma atualizacao de BIOS pode ser investigada pelo
operador, mas nao foi aplicada nem assumida como solucao.

Referencia: [early microcode no Linux](https://docs.kernel.org/arch/x86/microcode.html).

## Desktop: ownership, trust e somente quatro launchers

Antes: dois links absolutos em `/etc/skel/Desktop` apontavam para os launchers
PMJS em `/usr/share/applications`, controlados por root. Mesmo um link do usuario
continuava apontando para um alvo nao gravavel, causando o emblema/cadeado.
Os arquivos de menu de sistema continuam adequadamente controlados por root.

O usuario Live e criado **durante o boot**, pelo componente live-config
`0030-user-setup`, nao pelo hook chroot de build. A revisao remove os dois links
do skel e adiciona `1195-pmjs-desktop`, executado depois desse componente e antes
da sessao grafica. Ele interpreta o username do cmdline, resolve UID/GID/home
via NSS e instala copias regulares modo `0755` com o dono correto:

| Desktop | Origem do launcher / icone |
|---|---|
| PMJS Deploy | `pmjs-deploy.desktop` / PNG institucional `pmjs-deploy` |
| PMJS Image Builder | `pmjs-image-builder.desktop` / PNG institucional `pmjs-image-builder` |
| Firefox ESR | `firefox-esr.desktop` do pacote / `firefox-esr` |
| GParted | `gparted.desktop` do pacote / `gparted` |

Os launchers dos pacotes sao copiados sem reinventar Exec/Icon ou a elevacao
via polkit do GParted. Wrappers PMJS e sudo foram preservados. Cada novo boot
nao persistente recria os arquivos; a marca live-config evita repeticao no
mesmo boot. Nao ha UID hardcoded, `chmod 777` ou `chown -R`.

O componente recusa home/Desktop symlink e destinos que sejam diretorios ou
arquivos especiais; valida as quatro origens antes de copiar. Desliga apenas
links/arquivos com os quatro nomes conhecidos, evitando alterar o alvo de links
legados e hardlinks. Nao apaga dados desconhecidos do usuario. O skel fixa
`XDG_DESKTOP_DIR="$HOME/Desktop"`; `xdg-user-dirs` e dependencia explicita.

No [Caja 1.26.4](https://github.com/mate-desktop/caja/blob/v1.26.4/libcaja-private/caja-directory-async.c),
`is_link_trusted()` considera launchers locais no diretorio Desktop confiaveis,
alem dos launchers de sistema. Assim, as copias executaveis no Desktop nao
dependem de gravar `metadata::trusted` do GNOME/gio ou de uma sessao DBus de root.
A apresentacao/clique precisa de confirmacao grafica no proximo boot.

Defaults Caja ocultam icones virtuais Home, Computer, Trash, Network e volumes,
sem desativar montagem ou acesso pelo gerenciador de arquivos. Em sessao nova,
somente os quatro launchers acima aparecem; ferramentas secundarias vao ao menu.
Preferencias/arquivos adicionais de uma sessao persistente nao sao apagados.

## Flameshot e menu MATE

`flameshot` e fornecido pelo [Debian Trixie main](https://packages.debian.org/trixie/flameshot)
(`12.1.0+ds-2` na consulta). Foi acrescentado a package-list, sem repositorio
externo, sem atalho no Desktop. Seu launcher nativo continua no menu MATE.
O hook exige o binario; a validacao pos-build tambem exige `/usr/bin/flameshot`.

Autostart nativo `/etc/xdg/autostart/pmjs-live-keybindings.desktop`, exclusivo
MATE, executa `pmjs-live-keybindings` como usuario da sessao (nunca root). Ele
configura apenas o caminho relocatable
`org.mate.control-center.keybinding:/org/mate/desktop/keybindings/pmjs-flameshot/`
com nome de captura, action `flameshot gui` e binding `<Super><Shift>s`.
Isso usa o [plugin de keybindings do MATE](https://github.com/mate-desktop/mate-settings-daemon/blob/master/plugins/keybindings/msd-keybindings-manager.c),
nao chaves GNOME incompatíveis. Nao depende de dconf/DBus do HOST nem de
configuracao manual. Em sessao persistente, esse atalho institucional e
reaplicado ao login. Captura real/atalho visual so podem ser confirmados no boot.

PMJS Deploy e Image Builder ja usavam `/usr/share/applications` e
`Categories=System;`, com Exec/TryExec/Icon coerentes. Isso foi preservado.
Nao foi criado submenu PMJS: exigiria arquivos `.directory` e um merge XDG de
menu, mais superficie de manutencao sem necessidade para dois aplicativos.
Nao ha substituicao do menu MATE, duplicatas de entradas Firefox/GParted ou
launchers complexos. Ferramentas comuns conservam as categorias dos pacotes.

## VS Code: implementacao correta preservada

O pacote `code` ja esta declarado. Os arquivos `microsoft-vscode.list`, `.key`
e `.pref` em `config-live/archives/` usam o suporte nativo live-build, source
Microsoft HTTPS/stable/amd64 e `signed-by` explicito. Fingerprint da chave:
`BC52 8686 B50D 79E3 39D3 721C EB3E 94AD BE12 29CF`; SHA256 do arquivo publico
versionado: `2fa9c05d591a1582a9aba276272478c262e95ad00acf60eaee1644d93941e3c6`.

Nao foi necessario alterar essa integracao. `work/binary/live/filesystem.packages`
do build anterior registra `code 1.137.0-1788902055`, evidencia de resolucao e
instalacao durante aquele `lb build`. Checks existentes validam source, pinning,
checksum da chave, package-list e executavel final. Nao houve novo apt update ou
instalacao nesta rodada. Nao ha allow-unauthenticated, assinatura desabilitada,
curl|bash ou alteracao dos mirrors Debian. O canal stable nao fixa versao de
pacote: reprodutivel significa receita/configuracao controladas, nao ISO
byte-a-byte identica com repositorios mutaveis.

## Snapshots: nenhuma imagem PMJS na ISO

Os snapshots runtime versionados foram auditados por allowlist exata e tamanho.
Nao contem `.git`, caches, work, staging, outputs, logs, `pmjs-images/`, arquivos
`rootfs.tar.*`/`homefs.tar.*` ou bundles `pmjs-linux-*`. Maior arquivo auditado:
`deploy/lib/chroot_boot.sh`, 22.779 bytes. Nenhum snapshot foi atualizado e
nenhuma logica interna foi alterada. O Deploy incorporado conserva a descoberta
offline Ventoy; o Image Builder conserva build/publicacao/NFS/schema 1.

Checks, atualizador de snapshots e testes reforcam explicitamente a rejeicao de
`pmjs-images`, `staging`, `outputs`, stagings ocultos `.build.`/`.sync.` e arquivos
maiores que 20 MiB, alem das exclusoes anteriores. Copias continuam allowlisted.
Imagens offline pertencem somente a `<raiz Ventoy>/pmjs-images/`, fora da ISO.
Nao houve nova ISO nesta rodada; essa confirmacao refere-se aos includes que
alimentarao a proxima build, nao a uma ISO nova inexistente.

## Validacoes e pendencias

- `./tests/run.sh`: 24 grupos TAP, incluindo 21 testes unittest novos.
- Shell syntax dos scripts/hooks/componentes; validacao dos `.desktop` PMJS,
  autostart e dos launchers Firefox/GParted dos pacotes do chroot existente.
- UID/GID, modo 0755, quatro copias regulares, repeticao, symlink/hardlink seguro,
  recusa de destinos diretorio e fontes incompletas: fixtures locais.
- Proxy JSON/policies e ausencia de bancos de credenciais; atalho MATE com
  `id`/`gsettings` fakes, sem alterar dconf do HOST.
- Package-lists sem duplicatas, pacote Flameshot, Microsoft source/key/pinning,
  snapshot allowlist/exclusoes/tamanho e guardas contra staging.
- `glib-compile-schemas --strict` contra schemas do chroot existente, em
  diretorio temporario; leitura dos defaults e binding via backend memory.
- Early CPIO concatenado, Intel/AMD, revisao Haswell, checksum, truncamento,
  ausencia/duplicatas e arquivo comprimido que nao constitui early payload.
- Auditoria read-only do initrd extraido da ISO anterior: hash igual ao
  intermediario, Intel Haswell 0x28 presente, AMD early ausente (rejeicao esperada).
- Validacao do payload Intel real pelo novo parser (estrutura/checksums/Haswell),
  completando apenas o dicionario em memoria com firmware AMD do pacote:
  sucesso, sem gerar initrd/ISO ou aplicar microcode.
- `git diff --check`.

Nao foi executado `lb build`. Pendentes: resolucao APT atual de todos os pacotes,
geracao real do novo initrd, `about:policies`, autenticacao institucional,
apresentacao/clique dos quatro icones, atalho/captura Flameshot e aplicacao Intel
no i3-4160. Preservados: LightDM/autologin, Xorg, kernel/firmware grafico,
UEFI/Legacy/GRUB, snapshots/runtime Deploy e Image Builder.

## Arquivos alterados

Modificados: `README.md`, `docs/PHASE4_INTEGRATION.md`, `lib/build.sh`,
`lib/checks.sh`, `tests/run.sh`, `tools/update-pmjs-snapshots.sh`,
`config-live/package-lists/60-desktop-mate.list.chroot`,
`config-live/hooks/live/010-pmjs-baseline.hook.chroot` e
`config-live/includes.chroot/usr/share/glib-2.0/schemas/90_pmjs-live.gschema.override`.

Removidos somente os dois links legados em
`config-live/includes.chroot/etc/skel/Desktop/`: `PMJS Deploy.desktop` e
`PMJS Image Builder.desktop`. Os launchers de menu nao foram removidos.

Novos: `docs/LIVE_POLISH.md`, `tests/test_live_polish.py`,
`tools/validate-early-microcode.py` e, em `config-live/includes.chroot/`:

- `etc/default/intel-microcode`
- `etc/default/amd64-microcode`
- `etc/firefox/policies/policies.json`
- `etc/skel/.config/user-dirs.dirs`
- `etc/xdg/autostart/pmjs-live-keybindings.desktop`
- `usr/lib/live/config/1195-pmjs-desktop`
- `usr/local/libexec/pmjs-live-keybindings`

Nao houve alteracao de arquivos nos outros dois projetos ou nos snapshots.
`git diff --stat` nao inclui os dez arquivos novos enquanto nao forem adicionados
ao indice; nao foi feito staging/commit nesta rodada.
