# CellStudio no iPhone

O mesmo código do app do Mac (núcleo `CellCore` e painéis SwiftUI) compila para iOS 17+.
O que muda entre as plataformas fica em `Sources/CellStudio/Platform.swift`.

## Telas

| Aba do iPhone | Conteúdo (o mesmo do Mac) |
|---|---|
| **Estação** | Explorador de projeto (toque longo = menu de contexto), Características, menu Arquivo (backup, estação, carroceria, peça, KRL, pasta de modelos 3D, catálogo), desfazer/refazer |
| **Vista 3D** | Ribbon Vista 3D / Objetos 3D / Simulação, cena 3D (um dedo gira, dois movem/aproximam, toque num ponto do caminho seleciona o comando, toque longo soma à seleção), barra de simulação |
| **Editor** | Ribbon Editor de programa / Ferramentas, abas de módulos, Código fonte e Dados, comandos e folhas de edição. "Selecionar" liga a seleção de várias linhas (copiar, recortar, colar, excluir, transformar pontos) |
| **Análise** | Análise da estação (sugestões abrem em folha), Bits de colisão, Claude |
| **Mensagens** | Mensagens, Online (robô virtual, gateway TCP, jog) |

O ribbon de cada tela rola na horizontal; o botão ao lado das abas recolhe para dar espaço.

## Arquivos no iPhone

- Backups de robô, a pasta `3DObjects` (≈ 950 MB) e as estações vêm do app **Arquivos** (iCloud Drive, "No meu iPhone", pendrive USB-C).
  O app lembra as pastas escolhidas e reabre o acesso no próximo início.
- Os Documentos do app aparecem em **Arquivos ▸ No meu iPhone ▸ CellStudio**. Uma pasta `3DObjects` copiada para lá é achada sozinha.
- "Salvar estação", "Exportar KRL", "Exportar STL/USDZ" e "Exportar mensagens" gravam o arquivo e abrem a janela de exportação do iOS.
- O iOS não deixa apps usarem a Lixeira: o que o app manda para a Lixeira vai para `Documentos/Lixeira` (dá para recuperar pelo app Arquivos).
- "Mostrar no Finder" vira **Compartilhar…**.

## Claude no iPhone

No Mac o painel Claude usa o comando `claude` (Claude Code) e o servidor MCP local. No iPhone não há linha de comando:
a conversa vai direto para a API do Claude (`ClaudeAPIChat.swift`, modelo `claude-opus-5-5`) com as **mesmas ferramentas da estação**
(`MCPTools`), executadas dentro do app. É preciso uma chave da API (console.anthropic.com ▸ API Keys), informada no botão
**Chave da API** do painel; ela fica só no Keychain do aparelho. O uso é cobrado na conta da API.

## Compilar

Só com as Command Line Tools (o que existe hoje neste Mac):

```bash
./build-ios.sh check      # compila o app iOS (como Mac Catalyst) e mostra erros
./build-ios.sh catalyst   # build/ios/catalyst/CellStudio-Catalyst.app: o app do iPhone rodando no Mac
```

Diagnóstico com captura (janela no tamanho de um iPhone):

```bash
build/ios/catalyst/CellStudio-Catalyst.app/Contents/MacOS/CellStudio --snapshot /tmp/p.png --tab 3d \
  --models ../_analise/inst/3DObjects --backup ../R11 --program under --seek 0.45
```

`--tab` aceita `station`, `3d`, `editor`, `analysis`, `messages`; `--analyze` roda Simular e analisar antes da captura.

Com o **Xcode** instalado (App Store):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
./build-ios.sh sim        # compila para o Simulador e instala no simulador que estiver ligado
```

Para o **iPhone de verdade** a Apple exige assinatura, feita pelo Xcode:

```bash
brew install xcodegen
cd ios && xcodegen        # gera ios/CellStudio.xcodeproj a partir de project.yml
open CellStudio.xcodeproj
```

No Xcode: alvo CellStudio ▸ Signing & Capabilities ▸ Team = seu Apple ID; ligue o iPhone no cabo, ative o Modo de
Desenvolvedor no iPhone (Ajustes ▸ Privacidade e Segurança) e clique em Run. Com Apple ID gratuito o app vale por 7 dias;
com a conta paga de desenvolvedor, 1 ano (ou TestFlight).

## Limitações conhecidas

- Testado no Simulador (iPhone 17 Pro Max, iOS 26.5): abrir backup pelo app Arquivos, modelos 3D da Dürr, simulação, gestos,
  editor e análise. Ainda não foi instalado num iPhone de verdade.
- O iPhone diferencia maiúsculas nos nomes de arquivo (o Mac não). O catálogo da Dürr às vezes erra (`EcoRs_Kuka` × `EcoRS_Kuka`);
  `AppState.findFile` acha cada pasta ignorando maiúsculas.
- OPC DA/DCOM continua indisponível (como no Mac). Robô virtual e gateway TCP funcionam; o iOS pede permissão de rede local.
- Teclas de atalho do Mac (⌘C, Delete…) não existem no iPhone; as mesmas ações estão no menu de contexto e na barra do Editor.
- O servidor MCP local (para o Claude Code de um Mac usar a estação) só roda no Mac.
