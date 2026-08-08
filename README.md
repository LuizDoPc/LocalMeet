<div align="center">
  <img src="Resources/AppIcon-1024.png" width="128" alt="Ícone do LocalMeet">

  # LocalMeet

  **Suas reuniões, transcritas e organizadas sem sair do seu Mac.**

  Capture o áudio do sistema e do microfone em trilhas independentes, preserve o idioma original e gere traduções, resumos e próximos passos usando modelos locais.

  [![macOS 15+](https://img.shields.io/badge/macOS-15%2B-111111?logo=apple)](https://www.apple.com/macos/)
  [![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
  [![Processamento local](https://img.shields.io/badge/privacidade-processamento%20local-2E7D32)](#privacidade)
  [![Release](https://img.shields.io/github/v/release/LuizDoPc/LocalMeet?display_name=tag)](https://github.com/LuizDoPc/LocalMeet/releases/latest)
</div>

---

## O que ele faz

- Captura **áudio do sistema e microfone separadamente**, inclusive quando as falas se sobrepõem.
- Transcreve reuniões com **Português, English e Deutsch** na mesma conversa.
- Detecta mudanças de idioma dinamicamente, sem substituir o texto original.
- Exibe traduções sob demanda nos três idiomas e valida o idioma produzido.
- Gera resumo, decisões, datas importantes e action points com responsável e prazo.
- Permite marcar ações como concluídas e registra a data de conclusão.
- Organiza reuniões com tags, busca e filtros.
- Exporta cada reunião como Markdown.
- Mostra diagnósticos de sinal do microfone e do áudio do sistema após a captura.

## Privacidade

O LocalMeet foi desenhado para manter o conteúdo da reunião no dispositivo:

- O [whisper.cpp](https://github.com/ggerganov/whisper.cpp) faz a transcrição e a detecção de idioma localmente.
- O Foundation Models da Apple gera traduções e análises no dispositivo, quando disponível.
- Os arquivos de áudio existem apenas durante o processamento e são removidos ao final.
- As transcrições ficam em `~/Library/Application Support/LocalMeet/meetings.json`.
- Nenhum servidor próprio, conta ou chave de API é necessário.

> Na primeira execução, o app baixa o modelo multilíngue `small` do whisper.cpp, com aproximadamente 466 MB. Depois disso, a transcrição funciona offline.

## Instalação

1. Baixe o DMG na página de [Releases](https://github.com/LuizDoPc/LocalMeet/releases/latest).
2. Abra o arquivo e arraste o **LocalMeet** para **Aplicativos**.
3. Autorize **Microfone** e **Gravação de Tela e Áudio do Sistema** quando o macOS solicitar.
4. Escolha o dispositivo de entrada na tela inicial ou em **Ajustes**.

O build atual usa assinatura ad hoc e ainda não é notarizado. Caso o macOS bloqueie a primeira abertura, clique com o botão direito no app, escolha **Abrir** e confirme.

## Requisitos

| Recurso | Requisito |
| --- | --- |
| Captura e transcrição | macOS 15 ou mais recente |
| Tradução, resumo e action points | macOS 26 com Apple Intelligence habilitado |
| Arquitetura do DMG atual | Apple Silicon |
| Compilação do código | Xcode 16+, Swift 6 e Homebrew |

## Como funciona

```text
Áudio do sistema ── ScreenCaptureKit ─┐
                                      ├─ arquivos temporários separados
Microfone ──────── AVFoundation ──────┘
                                                   │
                                                   ▼
                                     whisper.cpp multilíngue
                                                   │
                               transcrição original + linha do tempo
                                                   │
                                                   ▼
                              Foundation Models no dispositivo
                             tradução · resumo · decisões · ações
```

As duas fontes são transcritas independentemente e só depois mescladas pela linha do tempo. Isso mantém os segmentos **Você** e **Reunião** separados mesmo durante sobreposição de fala.

## Desenvolvendo

Instale as dependências nativas:

```bash
brew install whisper-cpp ggml libomp
```

Compile e execute os testes:

```bash
swift build
swift test
```

Gere o bundle do aplicativo:

```bash
./scripts/build-app.sh
open dist/LocalMeet.app
```

Gere o DMG distribuível:

```bash
./scripts/build-dmg.sh
```

O script inclui o runtime do whisper.cpp dentro do `.app` e aplica uma assinatura ad hoc. Para distribuição ampla, substitua-a por uma identidade Developer ID e faça a notarização com a Apple.

## Stack

- SwiftUI
- ScreenCaptureKit
- AVFoundation
- whisper.cpp (`small`, multilíngue)
- Apple Foundation Models
- Swift Testing

## Dados e permissões

O LocalMeet solicita apenas as permissões necessárias para capturar as duas fontes de áudio. Se uma gravação vier sem sua voz, confirme o microfone escolhido em **Ajustes**; o indicador de diagnóstico da reunião informa qual entrada foi usada e se houve sinal.

---

<div align="center">
  Feito para reuniões multilíngues — e para continuar funcionando quando a internet não funciona.
</div>
