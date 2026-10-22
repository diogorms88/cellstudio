# CellStudio – recriação para macOS do DXQ3D.onsite (Dürr)

App nativo (Swift/SwiftUI + SceneKit) para Apple Silicon. Código novo, escrito a partir da
análise do DXQ3D.onsite 4.5.3: arquitetura, formatos e dados de catálogo. Nenhum código da Dürr
foi copiado e o sistema de licença deles não foi tocado.

## Compilar e rodar

```bash
./build.sh          # gera build/CellStudio.app
./build.sh test     # verificações do núcleo (cinemática, KRL, pintura)
open build/CellStudio.app
```

Usa só as Command Line Tools: o SwiftPM delas falha ao linkar o manifesto, então o build chama `swiftc` direto.

### GitHub, Download e atualização

- Repositório: https://github.com/diogorms88/cellstudio. Pastas de dados: `flash's/` (backups dos robôs) e `bodies/` (carrocerias e a 3DObjects).
- No app, **Download** (iPhone: botão ⬇︎ na aba Estação; Mac: Arquivo ▸ Download) lista e baixa essas pastas, só o que mudou.
- Cada build grava o commit em `build-info.json`; o app avisa quando o GitHub tem versão mais nova.
- Atualização do iPhone pelo Mac: `tools/install-updater.sh` instala um serviço (launchd) que a cada 30 min busca o GitHub e,
  com commit novo ou assinatura com mais de 5 dias, compila e instala no iPhone conectado (cabo ou Wi-Fi).
  Log em `~/Library/Application Support/CellStudio/updater/updater.log`; remover com `tools/install-updater.sh --remove`.

### iPhone

O mesmo código compila para iOS 17+ (telas Estação, Vista 3D, Editor, Análise e Mensagens). Ver `ios/README.md`.

```bash
./build-ios.sh check      # compila o app iOS (Mac Catalyst, sem Xcode)
./build-ios.sh catalyst   # o app do iPhone rodando no Mac, para testar
./build-ios.sh sim        # Simulador do iOS (precisa do Xcode)
```

Diferenças entre Mac e iPhone ficam em `Sources/CellStudio/Platform.swift` (cores, diálogos, seletores de arquivo,
área de transferência); as telas do iPhone em `PhoneApp.swift`; o Claude pela API (iPhone) em `ClaudeAPIChat.swift`.

## O que o original é (análise)

| Área | Original (Windows) | Situação no CellStudio |
|---|---|---|
| Interface | WPF + Infragistics + Prism, ~1,4 mi linhas C# | SwiftUI |
| 3D | HOOPS (hoops.dll), modelos `.hsf` | SceneKit; robô desenhado a partir do DH; STL/OBJ/USD |
| Catálogo de robôs | `3DObjects/Robots/DurrRobotTypesFiles.xlsx` | convertido em `robots.json` (`tools/convert_robot_catalog.py`) |
| Cinemática | `InverseKin.dll` nativa + catálogo do backup do controlador | IK numérica própria (DLS, várias sementes) |
| DH | T = Rz(θ)·Tz(d)·Tx(a)·Rx(α) (`DhParameters.GetFrame`) | igual |
| Programas | EcoTalk `.tip/.tid` (comandos vêm das declarações do controlador), KRL `.src/.dat` | EcoTalk (ler, editar, simular) e KRL (ler/escrever) |
| Pintura | EcoPaintJet / ProcessSimulation | modelo de leque cônico com balanço de massa |
| Comunicação | OPC DA (DCOM), CommLib nativa (RPC/EcoEmos), Siemens S7, gRPC | robô virtual + gateway TCP |

## Backups de robô (flash do controlador)

`Arquivo ▸ Abrir backup de robô…` aceita a pasta do flash (ex.: `R11/`) ou o backup completo (`R22/application/...`).
O CellStudio lê:

- `config/machinedata1.cfg`: base do robô na estação, parâmetros DH dos 6 eixos, limites, velocidades e trilho (pre/postLinkFrame).
- `teachcontrol/kin1/*.tt`: projetos EcoTalk (`.tip` instruções, `.tid` dados) e `_global.tt/_globalvars.tid` (ferramentas, objetos, velocidades).

Validação com R11 e R22 (estação 6001): o TCP calculado nos pontos articulares (Axis) fica em mediana a 123/205 mm do
ponto cartesiano seguinte (Object). As leituras alternativas dão 1,5 a 4 m: trilho invertido, ângulos na convenção KUKA ou sem trilho.

Convenção de ângulos da Dürr: R = Rz(C)·Ry(B)·Rx(A). A KUKA usa o inverso, e o import/export de KRL converte.

## Fases

1. **Feito:** cinemática, catálogo, cena 3D, KRL, simulação de espessura, robô virtual, estação `.cellstation`.
1b. **Feito:** leitura do machinedata e de programas EcoTalk do backup, simulação com SETTOOL/SETOBJECT/GUN/CALL, interface no layout do DXQ (ribbon, explorador, características, editor, mensagens).
2. **Feito – leitor `.hsf`** (`Sources/CellCore/HSF.swift`, `Edgebreaker.swift`): lê os modelos 3D do DXQ (1146 de 1311 arquivos com geometria; 94 de 98 elos de robô do catálogo). Robôs de backup são associados automaticamente ao tipo do catálogo pelo DH; o elo Kn+1 é posicionado no frame após n eixos, como o DXQ faz em `H3DRobot.LoadRobotJointFiles`.
3. **EcoTalk completo:** saltos (IF/GOTO/LABEL), laços, trigger frames e E/S. Hoje essas instruções aparecem como aviso e não são executadas.
4. **Comunicação:** OPC UA e S7 nativos no Mac. OPC DA/DCOM não existe no macOS, então ou um gateway Windows ou a substituição por OPC UA na planta.

## Limitações atuais

- Robôs escolhidos só pelo catálogo (sem backup) usam altura da base e ângulos α típicos. Com o backup, os valores são exatos.
- A pintura não considera sombreamento nem efeito eletrostático.
- Os modelos 3D são lidos da pasta `3DObjects` extraída do instalador (Vista 3D ▸ Modelos 3D…). Trilho e ferramentas usam esses modelos; carrocerias HSF/STL são importadas em Objetos 3D.
- Leitor `.hsf`: o opcode R (opções de renderização) é pulado por ressincronização; polilinhas compostas e alguns arquivos raros (precision wrist, alguns Kawasaki) ainda não carregam.
- A carroceria é um arquivo separado do backup. Em **Objetos 3D ▸ Importar carroceria**, escolha HSF/STL e o OBJECT (ex.: R11 / S202). É possível trocar o OBJECT nas propriedades e salvar o vínculo na estação.
