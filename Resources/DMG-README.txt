LOCALMEET — INSTALAÇÃO

1. Arraste LocalMeet para a pasta Applications.
2. Abra o LocalMeet. Se o macOS bloquear a primeira abertura, clique com o botão direito no app e escolha Abrir.
3. Na primeira reunião, autorize Microfone e Gravação de Tela e Áudio do Sistema.
4. O app baixa uma vez o modelo multilíngue de aproximadamente 466 MB. Depois, transcrição, traduções e resumos são processados localmente.
5. Você pode iniciar outras reuniões enquanto o app processa as anteriores. A fila e o progresso de cada etapa aparecem dentro do app.
6. Durante a gravação, use Silenciar meu microfone ou ⇧⌘M. Somente sua voz é silenciada; o áudio do sistema continua normalmente.
7. No detalhe da reunião, clique no título ou nos ícones de lápis para corrigir textos. Action points, decisões e datas também podem ser editados ou apagados.
8. Para cada resumo, escolha LLM local ou Claude. O modo Claude usa o Claude Code já instalado e autenticado neste Mac e envia a transcrição à Anthropic.
9. Para identificar participantes individuais, instale ffmpeg e WhisperX, aceite os termos do modelo pyannote community-1 e salve um token de leitura do Hugging Face em Ajustes. O token fica protegido no Keychain e a identificação roda localmente.
10. Depois da identificação, nomeie as vozes na reunião ou use a aba Contatos. O nome passa a aparecer em todas as falas vinculadas.

REQUISITOS

- Mac com Apple Silicon
- macOS 15 ou posterior
- macOS 26 com Apple Intelligence para traduções e resumos
- WhisperX e ffmpeg para identificação opcional de participantes

PRIVACIDADE

O áudio é apagado depois que a transcrição e a identificação de participantes terminam. Se uma etapa falhar, as duas trilhas ficam preservadas localmente para uma nova tentativa. O texto e os contatos ficam em ~/Library/Application Support/LocalMeet.
