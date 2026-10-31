# Contribuir com o Lar

**Português** · [English](#contributing-to-lar)

O Lar é gratuito e de código aberto, feito pela [Coupled](https://www.coupled.com.br). Toda ajuda é bem-vinda.

## Relatar um problema ou sugerir uma ideia

Abra uma [issue](https://github.com/coupledtec/Lar/issues/new) contando:

- o que aconteceu e o que você esperava;
- o aparelho (Mac, iPhone, relógio…) e a versão do Lar (em **Sobre o Lar**);
- o relatório do **Diagnóstico** (Ajustes → Diagnóstico → copiar). Ele não tem nenhuma chave nem senha.

Nunca cole tokens, senhas ou chaves numa issue.

## Contribuir com código

1. Faça um **fork** do repositório e crie um branch a partir do `main`.
2. Compile e rode os testes: `scripts/test.sh`. Detalhes em [DEVELOPMENT.md](DEVELOPMENT.md).
3. Siga o estilo do código ao redor: Swift moderno, comentários curtos que explicam o porquê, textos da interface em
   português (o inglês vem do catálogo `Resources/Localizable.xcstrings`).
4. Toda mudança precisa de teste quando dá para testar sem rede (veja `Tests/LarCoreTests`).
5. Mande um **pull request** explicando o que muda e como você testou.

Integrações novas (uma marca, um aparelho) entram como um provider em `Sources/LarCore`. Antes de começar uma
grande, abra uma issue para conversarmos.

## Contribuir com dinheiro

Manter o Lar custa a anuidade de desenvolvedor da Apple (US$ 99 por ano) e muitas horas de trabalho. Para o Lar
continuar gratuito:

- [GitHub Sponsors](https://github.com/sponsors/coupledtec)
- [Buy Me a Coffee](https://buymeacoffee.com/coupled)
- **PIX** (CNPJ da Coupled): `41.107.909/0001-20`
- Nos apps da App Store: **Ajustes → Sobre o Lar → gorjeta**.

---

# Contributing to Lar

[Português](#contribuir-com-o-lar) · **English**

Lar is free and open source, made by [Coupled](https://www.coupled.com.br). All help is welcome.

## Reporting a problem or suggesting an idea

Open an [issue](https://github.com/coupledtec/Lar/issues/new) with:

- what happened and what you expected;
- the device (Mac, iPhone, watch…) and Lar's version (in **About Lar**);
- the **Diagnostics** report (Settings → Diagnostics → copy). It has no keys or passwords.

Never paste tokens, passwords or keys in an issue.

## Contributing code

1. **Fork** the repository and create a branch from `main`.
2. Build and run the tests: `scripts/test.sh`. Details in [DEVELOPMENT.md](DEVELOPMENT.md).
3. Follow the surrounding code's style: modern Swift, short comments that explain why, interface texts in Portuguese
   (English comes from the `Resources/Localizable.xcstrings` catalog).
4. Every change needs a test when it can be tested without the network (see `Tests/LarCoreTests`).
5. Send a **pull request** explaining what changes and how you tested it.

New integrations (a brand, a device) go in as a provider in `Sources/LarCore`. Before starting a big one, open an
issue so we can talk.

## Contributing money

Keeping Lar going costs Apple's yearly developer fee (US$ 99 a year) and many hours of work. To keep Lar free:

- [GitHub Sponsors](https://github.com/sponsors/coupledtec)
- [Buy Me a Coffee](https://buymeacoffee.com/coupled)
- **PIX** (Coupled's CNPJ, Brazil): `41.107.909/0001-20`
- In the App Store apps: **Settings → About Lar → tip**.
