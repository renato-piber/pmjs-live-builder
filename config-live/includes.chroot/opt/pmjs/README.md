# Aplicativos PMJS integrados

Esta imagem inclui snapshots runtime controlados de:

- `deploy/`: PMJS Deploy; execute por `/usr/local/bin/pmjs-deploy`;
- `image-builder/`: PMJS Image Builder; execute por
  `/usr/local/bin/pmjs-image-builder`.

Cada diretorio contem `VERSION` e `SNAPSHOT`, que registram a versao e o commit
de origem. Os snapshots nao sao checkouts Git e nao incluem testes, logs, caches
ou artefatos de imagem. Eles sao atualizados no repositorio do PMJS Live Builder
por `tools/update-pmjs-snapshots.sh` antes da construcao da ISO.
