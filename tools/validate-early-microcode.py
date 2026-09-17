#!/usr/bin/env python3
"""Valida os CPIOs *na frente* do initrd, sem extrair ou descomprimir arquivos."""
import argparse
import struct
import sys
from pathlib import Path


class InvalidInitrd(ValueError):
    pass


def read_exact(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise InvalidInitrd("CPIO early truncado")
    return data


def early_payloads(stream):
    payloads = {}
    archives = 0
    while True:
        # initramfs-tools pode concatenar varios CPIOs early com padding NUL.
        while True:
            byte = stream.read(1)
            if byte != b"\0":
                break
        if not byte:
            break
        magic = byte + stream.read(5)
        if magic not in (b"070701", b"070702"):
            # Aqui comeca o initrd principal comprimido; nao procurar nele.
            break
        stream.seek(-6, 1)
        archives += 1
        while True:
            header = read_exact(stream, 110)
            if header[:6] not in (b"070701", b"070702"):
                raise InvalidInitrd("Cabecalho CPIO early invalido")
            try:
                fields = [int(header[n:n + 8], 16) for n in range(6, 110, 8)]
            except ValueError as error:
                raise InvalidInitrd("Campos CPIO early invalidos") from error
            mode, size, name_size = fields[1], fields[6], fields[11]
            if not 1 <= name_size <= 4096 or size > 64 * 1024 * 1024:
                raise InvalidInitrd("Entrada CPIO early fora dos limites")
            name = read_exact(stream, name_size)
            if not name.endswith(b"\0"):
                raise InvalidInitrd("Nome CPIO sem terminador")
            read_exact(stream, -(110 + name_size) % 4)
            data = read_exact(stream, size)
            read_exact(stream, -size % 4)
            if name == b"TRAILER!!!\0":
                if size:
                    raise InvalidInitrd("Trailer CPIO invalido")
                break
            path = name[:-1].removeprefix(b"./")
            if path in (b"kernel/x86/microcode/GenuineIntel.bin",
                        b"kernel/x86/microcode/AuthenticAMD.bin"):
                if path in payloads or mode & 0o170000 != 0o100000 or not data:
                    raise InvalidInitrd("Payload microcode vazio, duplicado ou nao regular")
                payloads[path] = data
    if not archives:
        raise InvalidInitrd("Nenhum CPIO early antes do initrd principal")
    return payloads


def validate(path):
    with Path(path).open("rb") as stream:
        payloads = early_payloads(stream)
    validate_payloads(payloads)


def validate_payloads(payloads):
    for vendor in (b"GenuineIntel", b"AuthenticAMD"):
        if b"kernel/x86/microcode/" + vendor + b".bin" not in payloads:
            raise InvalidInitrd(f"Microcode early ausente: {vendor.decode()}")
    intel = payloads[b"kernel/x86/microcode/GenuineIntel.bin"]
    offset = 0
    haswell = False
    while offset < len(intel):
        if len(intel) - offset < 48:
            raise InvalidInitrd("Cabecalho Intel truncado")
        header = struct.unpack_from("<12I", intel, offset)
        size = header[8] or 2048
        if header[0] != 1 or size < 48 or size % 4 or offset + size > len(intel):
            raise InvalidInitrd("Atualizacao Intel invalida")
        words = struct.unpack_from(f"<{size // 4}I", intel, offset)
        if sum(words) & 0xFFFFFFFF:
            raise InvalidInitrd("Checksum interno Intel invalido")
        if header[3] == 0x306C3 and header[6] & 0x32 and header[1] >= 0x22:
            haswell = True
        offset += size
    if not haswell:
        raise InvalidInitrd("Atualizacao Haswell 0x306c3 >= 0x22 ausente")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("initrd")
    args = parser.parse_args()
    try:
        validate(args.initrd)
    except (OSError, ValueError) as error:
        print(f"ERRO: {error}", file=sys.stderr)
        return 1
    print("OK: microcode Intel/AMD early e atualizacao Haswell presentes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
