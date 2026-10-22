# CellStudio: estado do projeto e guia de continuidade

Última atualização: 07/10/2026 (importação da carroceria HSF concluída)

## 1. Propósito

Recriar para **macOS (Apple Silicon)** o **DXQ3D.onsite 4.5.3** da Dürr, um software Windows de programação e simulação de robôs de pintura e vedação (EcoRP/EcoRS, controladores EcoRPC).

- O app é **nativo**, em Swift, SwiftUI e SceneKit, com a interface **igual à do DXQ**.
- O código é próprio. O DXQ foi descompilado só para entender formatos, protocolos e algoritmos (interoperabilidade). Esta liberado a utilização do código oficial descompilado.
- Os dados reais usados são os da estação **6001 da VW Anchieta**, robôs **R11 e R22** (vedação/sealing, StandardArm = EcoRS 16 com trilho linear).

## 2. Onde está tudo

| Caminho (em `~/Desktop/DXQ Portavel/`) | Conteúdo |
|---|---|
| `CellStudio/` | **O app** (código, build, testes, docs) |
| `CellStudio/build/CellStudio.app` | App compilado (abre com duplo clique) |
| `CellStudio/README.md` | Visão técnica resumida |
| `CellStudio/CONTINUIDADE.md` | Este arquivo |
| `R11/` | Flash do controlador R11 (machinedata, programas EcoTalk) |
| `R22/` (+ `2026_..._R22.7z`) | Backup completo do R22 |
| `DXQ3Donsite_v4.5.3.1032_Setup_x64/` | Instalador original (MSI de 2 GB) |
| `_analise/src/` | Código C# descompilado do DXQ (101 módulos, ILSpy) |
| `_analise/files/` | DLLs da Dürr extraídas, `modules.ini` |
| `_analise/inst/3DObjects/` | **1311 modelos 3D `.hsf`** extraídos; o app lê daqui |
| `_analise/inst/Help/pt-BR/` | Ajuda oficial (capturas da interface usadas como referência visual) |
| `_analise/inst/Language/` | Textos de tradução do DXQ |
| `_analise/base_stream.dll`, `hoops_stream.dll` | Bibliotecas HOOPS usadas na engenharia reversa do `.hsf` |
| `_analise/Setup.cab` | Extração temporária de 2 GB, **pode ser apagada** (o MSI continua) |

Ferramentas instaladas: Homebrew `msitools`, `sevenzip`, `openjdk@21`, `ghidra`; .NET 8 + `ilspycmd` em `~/.dotnet`.

## 3. Como compilar e rodar

```bash
cd ~/Desktop/DXQ\ Portavel/CellStudio
./build.sh          # gera build/CellStudio.app
./build.sh test     # verificações do núcleo (todas devem passar)
open build/CellStudio.app
```

- O build usa `swiftc` direto, porque o SwiftPM das Command Line Tools falha ao linkar o manifesto.
- Não existe Xcode instalado.
- Modo de diagnóstico (gera uma captura da janela):

```bash
build/CellStudio.app/Contents/MacOS/CellStudio --snapshot /tmp/x.png --backup ../R11 --backup ../R22 --program under --seek 0.45
```

Uso no app: **Arquivo ▸ Abrir backup de robô…** → selecione `R11` e `R22` → duplo clique num programa no Explorador de projeto para simular.

## 3b. Versão iPhone (21/10/2026)

- Mesmo código para macOS e iOS 17+. `Platform.swift` concentra o que muda (NSColor/UIColor, NSAlert/UIAlertController,
  NSOpenPanel/UIDocumentPicker, Lixeira, área de transferência, impressão). Diálogos continuam síncronos nas duas plataformas
  (no iOS o laço principal roda até a resposta).
- `PhoneApp.swift`: app iOS com 5 abas que reaproveitam os painéis e as abas do ribbon do Mac (`DXQSimulationTab`,
  `DXQAnalysisTab`, `DXQOnlineTab` saíram de `MainWindow` para serem usadas nas duas).
- `ClaudeAPIChat.swift`: no iPhone o painel Claude chama a API do Claude com as ferramentas `MCPTools`.
- Build: `./build-ios.sh check|catalyst|sim|device`; projeto Xcode por `ios/project.yml` (XcodeGen). Detalhes em `ios/README.md`.
- Testado no Simulador do iOS (Xcode instalado em 21/10/2026) e como Mac Catalyst (`--snapshot`); ainda não num iPhone.

## 4. Arquitetura do código

```
Sources/CellCore/          (biblioteca, sem interface)
  Math.swift          Pose na convenção Dürr: R = Rz(C)·Ry(B)·Rx(A)  (A em X, C em Z; KUKA é o inverso)
  Robot.swift         RobotModel, DHJoint (T = Rz(θ)·Tz(d)·Tx(a)·Rx(α)), catálogo, associação a modelo 3D
  Kinematics.swift    FK (base → preLink → Tz(trilho) → postLink → DH) e IK numérica (DLS, várias sementes)
  MachineData.swift   leitor do machinedata1.cfg (MC.KINEMATIC:n)
  RobotBackup.swift   abre a pasta de flash/backup (config + teachcontrol/kin1)
  EcoTalk.swift       parser .tip/.tid + interpretador (PTP/LIN, SETTOOL/SETOBJECT, VEL, GUN, CALL)
  Program.swift       RobotProgram/ProgramPoint, KRL (KUKA) ler/escrever
  Paint.swift         Mesh, simulação de espessura de tinta, Trajectory (amostragem)
  STL.swift           leitor STL
  Connection.swift    robô virtual e gateway TCP de texto
  HSF.swift           leitor de HOOPS Stream File (.hsf): opcodes, segmentos, includes, instâncias
  Edgebreaker.swift   descompressão edgebreaker (esquema 2) das malhas HSF
Sources/CellStudio/        (app SwiftUI)
  AppState.swift      estado central (robôs, programa aberto, simulação, mensagens, modelos 3D)
  SceneController.swift  cena SceneKit (robôs, modelos reais, trilho, trajetória, peças)
  MainWindow.swift    ribbon (abas) + layout estilo DXQ
  Explorer.swift      Explorador de projeto + Características
  CodeEditor.swift    editor EcoTalk (números de linha, cores, linha em execução)
  MessagesPanel.swift Mensagens + barra de status
  Theme.swift         cores e componentes do tema Office 2013/Infragistics
Tests/CellCoreChecks/main.swift   testes (inclui R11/R22 reais se as pastas existirem)
tools/   convert_robot_catalog.py (xlsx → robots.json); hsf_*.py (protótipo Python do leitor HSF)
```

## 5. O que já foi feito

### Fase 1: base
- Cinemática direta e inversa, catálogo de 86 braços (de `DurrRobotTypesFiles.xlsx`), cena 3D, editor de pontos, KRL, simulação de espessura de tinta, robô virtual e arquivo de estação `.cellstation`.

### Fase 1b: dados reais e interface DXQ
- Leitura do `machinedata1.cfg`: base, DH, limites, velocidades e trilho com pre/postLinkFrame.
- **Convenções validadas com os programas reais.** O TCP dos pontos articulares fica a 123/205 mm (mediana) do ponto cartesiano seguinte. Leituras alternativas dão de 1,5 a 4 m. Teste automático incluído.
- Parser e interpretador **EcoTalk**: 30 projetos e 267 programas do R22, por exemplo `s202_new/under` com 94 movimentos e 55 com aplicação.
- Interface no layout do DXQ, com os termos em pt-BR da ajuda oficial: ribbon, Explorador de projeto, Características, Vista 3D com fundo azul, editor Código fonte/Dados, Mensagens e barra de status azul.

### Fase 2: leitor `.hsf` (modelos 3D reais)
- Formato entendido pela especificação pública da Tech Soft 3D e pela descompilação (Ghidra) do `base_stream.dll`:
  - byte "general" em versões ≥ 19.75;
  - vários blocos zlib separados por pausas;
  - edgebreaker esquema 2 (operações C/L/E/R/S, previsão por paralelogramo, códigos em cascata 2/6/…/31 bits, palavras de 32 bits MSB primeiro);
  - pontos quantizados e faixas de triângulos;
  - tags (`q`), refinamentos e instâncias (`&`);
  - referências (`s : r`), includes e segmentos por caminho relativo (`../_tgsN`), visibilidade (`V`) e heurísticas (`H`).
- O opcode `R` (opções de renderização) é **pulado por ressincronização com validação** (lookahead), porque não traz geometria.
- Resultado: **1146 de 1311** arquivos com geometria e **94 de 98** elos de robô do catálogo. Os 13 arquivos que a planilha cita e não existem no instalador ficam fora dessa conta.
- Montagem igual à do DXQ (`H3DRobot.LoadRobotJointFiles`): o elo **K(n+1) fica no frame DH após n eixos**, malhas em metros (×1000).
- Ao abrir um backup, o robô é associado automaticamente ao tipo do catálogo pelo DH. R11 e R22 → **EcoRS 16** (`EcoRS_Kuka/rs16_k1…k7`).
- Verificado visualmente: o R11 montado com encaixe perfeito, e o app mostrando R11 e R22 com os modelos reais.

### Fase 2b: trilho, carro, peças e pistola 3D
- `Sources/CellCore/Equipment.swift` lê a seção `[3DOnSiteRCU1]` do `config/rpcsetup.ini` (`EcoRailType`, `UsedTool`, `UsedPartN`). Comentários na mesma linha (`HL ;V, L…`) são ignorados.
- Ferramenta: `3DObjects/Tools/Tools.xml` (ToolId → .hsf), presa no flange.
  - R11: `EcoGun23DShort`.
  - R22: `EcoGun2_3D_2ACV1_4580_L400`.
- Peças do robô: `3DObjects/Robots/DurrRobotParts.xml` (PartId → categoria → `AttachedToJoint`), presas no frame do eixo.
  - R11: `rs_k6_ecogun_sealing_3d` (eixo 5).
  - R22: `rs_k3_peltier_small` (eixo 2) e `rs16_k6_ecogun2_3d` (eixo 5).
- Trilho: aba `AuxJointsFileAssignment` exportada para `Resources/rails.json` (`tools/convert_robot_catalog.py`).
  - A linha é escolhida pelo `auxAssignment` do tipo do catálogo (EcoRS 16 → `RAILHL`) e pelo ângulo do preLinkFrame (R11 A=−90 → arquivos `_l`; R22 A=+90 → `_r`).
  - As peças de 2000/1500 mm são distribuídas como em `H3DRobot.LoadRailModel`, cobrindo o curso mais a largura do carro.
  - O trilho fica no frame `base · T(0,0,rootOffset) · preLink`.
  - O carro (`schlitten_hl_ipr160`) fica no frame após o trilho (`frames[0]`) mais `rootOffset`.
  - `rootOffset` = translação Z da matriz raiz do arquivo K1 (−675 mm no EcoRS 16), como em `GetRootOffsetFromFirstPart`.
- **Correção no leitor HSF:** pontos quantizados com **8 bits** são bytes em sequência, não palavras de 32 bits. Isso corrigiu os "estilhaços" nos trilhos e ferramentas.
- Verificado por captura: R11 e R22 em trilhos HL espelhados, carro sob o robô, pistola no flange.
- Pendente: comparar a altura e orientação exatas com uma captura do DXQ real, se disponível. O posicionamento segue o código do DXQ, mas o `rootOffset` do trilho foi inferido.

### Fase 2c: carroceria HSF na estação
- Objetos 3D, menu Arquivo e menu nativo aceitam HSF; botão **Importar carroceria** aceita HSF/STL.
- Com backup aberto, escolhe-se um OBJECT de qualquer robô ou a origem da estação. O padrão é o último SETOBJECT do programa aberto, no robô ativo. Sem backup, mantém o posicionamento anterior.
- A malha HSF é concatenada em mm (×1000), com índices deslocados e normais calculadas; carregamento e reabertura de peças da estação acontecem em segundo plano.
- Propriedades permitem trocar OBJECT e editar a pose. `Part.objectName` e `StationFile.PartRef.objectName` guardam a identificação `robô / OBJECT` (ou `station`), distinguindo nomes iguais; arquivos antigos continuam abrindo.
- Avisos para geometria parcial, dimensões incomuns e mais de 2 milhões de vértices. Pintura HSF usa aresta mínima de 30 mm e evita subdividir peças acima de 2 milhões de vértices.
- **HSF 23:** consome os bytes CRC dos atributos usados pela carroceria e dos shells. CRCs são consumidos, não validados. Troca do decoder deflate de Compression pelo zlib do macOS para contabilizar exatamente os bytes consumidos; o anterior antecipava bytes e pulava o segundo bloco da carroceria. Sem dependências externas.
- Preserva aberturas/fechamentos de segmentos entre blocos zlib; isso impede que geometrias da biblioteca interna da pistola R22 apareçam longe da estação. Enquadramento considera os oito cantos de peças rotacionadas.
- Arquivo real `SAGA_HEV_reduzido 2.hsf`: leitura integral de **3.698.876 triângulos**, comprimento aproximado de 4,02 m. As cores da carroceria permanecem no material cinza padrão.
- Diagnóstico aceita `--part arquivo.hsf --object S202`, aguarda o carregamento e grava mensagens em `<captura>.txt`.
- Testes: `./build.sh test` inclui regressão da carroceria real quando presente; `./build.sh test-parts` verifica unidades, índices, seleção de OBJECT, troca de posição e persistência retrocompatível (requer os backups/modelos locais).

### Fase 2d: simulação multi-kin da estação
- A referência oficial foi localizada em `Durr.EcoScreen.ES_RCS.Simulation`: o DXQ cria um `StationControl` multi-kin, mantém todos os `ActiveRobots` no mesmo relógio e atribui um programa/queue a cada robô. O `RcsMultiKinematicSimulation` também coordena SyncStart/PLC, ordens, bits de colisão e esperas entre controladores.
- O CellStudio agora possui um modo **Todos os robôs** na aba Simulação. Cada robô pode receber um programa próprio, as trajetórias são calculadas em paralelo lógico, o slider usa a união dos tempos e a cena atualiza todos os robôs no mesmo instante. Os caminhos aparecem em cores diferentes; um robô que termina antes permanece no último estado.
- O fluxo de pintura durante a reprodução e `Simular espessura` também percorre os robôs preparados. A seleção dos programas é salva na estação por nome de robô e continua compatível com `.cellstation` antigos.
- Ainda falta executar no interpretador EcoTalk as esperas e sincronizações do controlador (`SYNCSTART`, `RECEIVE`, `SET/RECEIVE` de colisão, IF/laços e E/S). Sem essas instruções, a cinemática multi-kin permanece sincronizada por relógio, mas não bloqueia um robô quando o programa oficial esperaria outro.

### Fase 3: EcoTalk completo e bits de colisão
- `Sources/CellCore/EcoTalk.swift`: interpretador com contador de programa.
  - Fluxo: IF/ELSIF/ELSE/END_IF, LOOP n DO/END_LOOP, WHILE…DO/END_WHILE, LABEL/GOTO, RETURN/EXIT e atribuição `X := expr`, com avaliador de expressões (NOT/AND/OR/XOR, comparações, aritmética, funções).
  - CIRC com ponto intermediário (arco por 3 pontos em `Paint.swift`, `Arc`).
  - Limite de 200 mil instruções contra laço infinito.
  - Condições externas (offline): `GET_BOOL_SYSTEMVAR` assume verdadeiro, ou seja, o caminho normal de produção. Dá para trocar por variável em `systemVariables`. `GET/SET_MOTION_STATE` é rastreado internamente. Cada suposição gera uma mensagem.
  - SET/RECEIVE de bits High/Low e DELAY viram `EcoTalkSyncAction` (com `afterPoint`).
- `Sources/CellCore/Station.swift`: `CollisionBits` e `StationScheduler`, com a mesma regra de `ES_RCS.Simulation/Models.IO/CollisionBits.cs` do DXQ.
  - High = 0 e Low = 1 (como no `system.ttu`).
  - O bit é uma zona compartilhada da estação. `SET High` pede a zona; o pedido vai para uma fila ordenada por tempo e depois pelo nome do robô. `SET Low` libera.
  - `RECEIVE High` só passa para o dono; `RECEIVE Low` passa se a zona está livre ou é de outro. Um `SET` pendente bloqueia o `RECEIVE` (como `_pendingSetCollisionBitCommands`).
  - Ao fim do programa, o robô libera as zonas dele (`RemoveActiveRobot`).
  - Relógio comum de 20 ms; quem espera fica parado na pose.
  - Impasse (todos esperando por 30 s): registra aviso e força a passagem do primeiro.
- `AppState.schedule(_:)` aplica o escalonador tanto no modo de um robô quanto no "Todos os robôs". Os eventos vão para Mensagens (nível Simulação/Aviso) e para `stationEvents`.
- Testes novos em `Tests/CellCoreChecks`: fluxo EcoTalk, CIRC, ações, espera de zona (B espera ~1,9 s por A) e impasse.
- Dados reais: R11 `s202_new/main` usa Collision1–8 em `under`/`under2`; R22 `Saveiro_MSE/Main` usa Collision3 em `Assoalho`. Juntos não se bloqueiam, porque as zonas são usadas em tempos diferentes.
- Pendente: TRIGGERFRAME (atraso/antecipação do GUN); E/S que não são bits de colisão (ex.: `RECEIVE(VISION, Data)`).

### Fase 3b: ajustes da estação (07–08/10/2026)
- Aba Simulação: botão "Todos para home" (RHOME do backup) e faixa da aba reorganizada (colunas de até 3 botões, programas da estação em grade, rolagem horizontal se não couber).
- Correção: na simulação conjunta, todo robô com backup é interpretado a partir do programa escolhido em "Programas da estação", inclusive o robô ativo. Antes, o robô ativo perdia os SET/RECEIVE quando a sessão era restaurada.
- Correção: abrir um programa no explorador não troca mais o programa do robô na estação. "Simular programa" troca.
- Correção: arquivos `.tip` com CRLF tinham os números de linha dobrados nas mensagens.
- Validado com a estação 6010 (R11/R12/R21/R22, `Nivus_MSE/Main`): o R21 espera cerca de 25,8 s pelo Collision1 do R11. Atenção: `Home.tip` faz `SET(Collision1..16, Low)` e `Assoalho_CUV.tip` do R11 tem o próprio par High/Low, e os dois liberam a zona.
- Diagnóstico: `--tab "Simulação"`, `--all` (todos os robôs), `--station arquivo.cellstation` (carrega uma sessão salva).
- **Painel de bits de colisão** (`Sources/CellStudio/CollisionBitsPanel.swift`): aba "Bits de colisão" ao lado de Mensagens (`BottomDock`).
  - Gantt com uma faixa por bit, colorida pelo robô dono da zona, e uma faixa por robô com as esperas em RECEIVE. Esperas forçadas por impasse aparecem em vermelho.
  - Cursor vermelho segue a simulação; clicar ou arrastar no gráfico leva a simulação àquele instante. Zoom e filtro "Só bits com espera".
  - Clicar numa espera abre o programa/linha do RECEIVE no editor sem trocar o robô ativo (`AppState.reveal`).
  - Dados: `StationScheduler.Output.zones` (`ZoneInterval`) e `.waits` (`WaitInterval`, com `blockedBy`, `forced`), publicados em `AppState.stationZones/stationWaits`.
  - Diagnóstico: `--bits` abre a aba; `--seek f` com `--station`; `--reveal` simula o clique na maior espera.

### Fase 4: editor de programa por comandos (08/10/2026)
Baseado no ProgramEditor do DXQ (`ProgramEditorViewModel.InitContextMenu`, `CommandEditorView`, `EcoTalkDeclarations.AddNativeCmd`, `EcoTalkTid.GetNewTypeInstanceName`). O .tip deixou de ser texto livre: é uma lista de comandos, uma linha cada.
- `Sources/CellCore/SystemTTU.swift`: lê `teachcontrol/_system.tt/system.ttu`.
  - Enums (`TYPE X : (a, b)`), rotinas (`ROUTINE NOME (p : TIPO; OPTIONAL …) : RET { macro="GRUPO"|enable="…" }`) e blocos de dados (`BLOCK POINT { prefix="P" }` com campos e padrões).
  - Comandos da linguagem (CALL, IF, ELSIF, ELSE, WHILE, LOOP, LABEL, GOTO, RETURN, atribuição e comentário) entram nos grupos Lógica/Comentário.
  - `insertGroups(showAll:)` monta o menu "Inserir um comando". Rotinas com `enable` só aparecem com "Mostrar todos os comandos" ou se já forem usadas.
  - Carregado em `RobotBackup.system`.
- `Sources/CellCore/ProgramEditing.swift` (`EcoProgramLine`, `EcoProgramEditor`): operações linha a linha que preservam CRLF e indentação.
  - Inserir (blocos levam o END_*), remover, mover, comentar/retirar comentário, desativar/ativar (`##`, que o interpretador ignora) e inverter sentido.
  - Dados no .tid: criar/substituir no fim da seção `// TIPO`, nome livre (P/TRG/New + nº, ou o prefixo já usado no programa), renomear (.tid + .tip), reindexar pontos e listar bits de colisão.
- Interpretador: `EcoTalkRunResult.frames` guarda SETTOOL/SETOBJECT em vigor por linha (`EcoFrameContext`). O "Modificar" usa isso para gravar a posição atual em Object/World.
- App (`ProgramCommandsView.swift`, `ProgramEditorActions.swift`):
  - Aba Código fonte: lista com nº de linha e cores do DXQ, linha da simulação em amarelo, multisseleção, barra de ferramentas e menu do botão direito na ordem do DXQ.
    - Itens do menu: Recortar, Copiar, Colar, Desfazer, Refazer, Remover, Modificar, Editar, Inserir ▸ grupos, Selecionar todos/iguais, Desmarcar, Comentário, Desativar/Ativar, Abrir subprograma / Abrir e simular (CALL), Bits de colisão usados, Inverter sentido, Reindexar pontos, Mover robô até o ponto, Mover para cima/baixo.
    - Duplo clique abre o diálogo do comando.
  - Diálogo de comando: um campo por parâmetro conforme o tipo (enum → lista, POINT/TOOL/OBJECT/… → dados existentes ou "＋ Novo", número, texto/expressão, programa para CALL).
    - Na inserção, POINT e TRIGGERFRAME são criados novos (posição atual do robô), como no DXQ.
  - Aba Dados: tabela (nome, tipo, valor, usos) com Novo/Editar/Modificar/Mover até/Remover (só sem uso). O diálogo de dado usa os campos do BLOCK.
  - Características: mostra o comando selecionado (parâmetros e coordenadas do ponto).
  - Desfazer/Refazer: pilha de até 200 estados (.tip + .tid). Copiar/colar leva os pontos junto; se o nome já existir com outro valor, renomeia.
- Diagnóstico: `--insert NOME`, `--edit-line N`, `--data`, `--editor-selftest` (tudo em memória). O snapshot também grava o diálogo aberto em `<arquivo>.sheet.png`.
- Ainda não feito: recolher/expandir seções, "Valor de instrução" (forçar IF na simulação), deslocar início do programa, suavizar orientação/DOF e impressão.

### Fase 5: erros de cinemática na simulação (08/10/2026)
Origem no DXQ:
- `ES_RCS.Simulation/Models/RcsDevice.cs`: `CheckJointLimits` com a correção ±360° (`tryToFix`), `CheckAndRaiseWarnings`, `CheckUserDefinedWarningLimits`.
- `CalculatedValues/JointLimitWarningInfo.cs`, `JointWarningState.cs` e `SingularityWarningState.cs`.
- `DirObjects.Config/RobotTypeHelper.CalculateSingularityValue`: |A5| mod 360.
- `files/McuErrors.ini`: códigos e textos dos erros do MCU. O MCU em si (interpolador do controlador) é código nativo e não dá para portar; as verificações foram refeitas.

Implementação:
- `Sources/CellCore/MotionDiagnostics.swift`: `JointLimits.check` (porte do `CheckJointLimits`), `JointLimits.warnings` (margem por eixo e singularidade), `MotionIssue` e `McuMessage` (textos pt-BR com o código MCU).
- `Trajectory.sample` devolve `issues`:
  - Alvo cartesiano: IK dentro dos limites; se falhar, IK livre (`respectLimits: false`). Se a IK livre converge, o erro é limite de eixo (536). Se não converge, é fora de alcance: posição (571) ou orientação (572).
  - Ponto Axis fora do limite e trilho fora da faixa: 536.
  - LIN/CIRC: cada passo resolve a partir do anterior (`solveFrom`, sem trocar de configuração). Detecta limite no caminho (502/503/504), salto > 90° num passo (545), punho singular |A5| < 0,5° (574) e velocidade de eixo acima do máximo (como o MCU 530, só informação: o controlador reduz a velocidade).
- `AppState.reportKinematics`: cada erro vai para Mensagens (Erro/Aviso/Simulação) com robô, programa:linha e [MCU nnn], mais o resumo "Simulação com N erro(s) de cinemática". Os pontos com erro ficam vermelhos na trajetória. A lista fica em `kinematicIssues`.
- Avisos configuráveis por robô (Características do robô → "6 - Limites de aviso"): margem antes do limite (A1…A6 e trilho) e singularidade |A5| ≤ x°. Desligados por padrão, como no DXQ. Ainda não são salvos na estação.
- Estação 6010 / Nivus_MSE: R11 `Assoalho_CUV` P63–P75 precisa A2 > 43° (máx. do machinedata) e R21 `Assoalho_CUV_INVERSE` P55 precisa A5 = -125,3° (mín. -125°). Falta conferir no DXQ se são reais ou se vêm do OBJECT nominal (sem a correção da visão `RECEIVE(VISION, Data)`).

### Fase 6: execução da simulação como no DXQ (08/10/2026)
Origem: `EcoTalkRcsDevice.cs` (fim com `Simulation_FinishedWithErrors` / `Simulation_FinishedSuccessfully`, `MarkCurrentPositionAsInvalid`) e `RcsDevice.OnMessageChanged` (mensagens com o tempo do passo).
- Abrir ou recalcular **não publica mais** os resultados. `buildRunEvents` monta a fila `simEvents`, já no relógio da estação (depois dos bits de colisão). A fila tem:
  - notas do interpretador;
  - "programa:linha – comando" no início de cada movimento;
  - erros/avisos de cinemática (tempo levado de `rawStarts` para a trajetória escalonada);
  - eventos dos bits.
- ▶ do início (`beginRunLog`): apaga as mensagens da execução anterior e tira o vermelho. Durante o play, `advanceEvents(to:)` solta as mensagens até o instante atual.
- No primeiro erro, com "Parar no erro" (faixa Simulação, ligado por padrão):
  - a simulação para no ponto e o robô fica vermelho (`SceneController.setRobotError`, com cópia dos materiais);
  - aparece a faixa vermelha na Vista 3D (`SimulationStopBanner`), com robô, programa:linha e mensagem;
  - o editor abre a linha do erro em vermelho (`editorErrorLine`).
  - ▶ de novo continua dali.
- Fim (`finishRun`): tempo parado nos bits e "Simulação concluída com sucesso (x s)" ou "… com erros (N)".
- Arrastar o tempo para trás recoloca a fila (`syncEvents`).
- Diagnóstico: `--play` (velocidade 25×; o snapshot espera parar) e `--no-stop`. O .txt do snapshot inclui "FAIXA: …".

### Fase 7: análise da estação com IA (08/10/2026)
Objetivo do projeto: a IA estuda a programação e a trajetória e mostra (1) onde reduzir o tempo de ciclo HOME-to-HOME sem mexer em VEL/ACC e (2) onde há risco de colisão robô × robô e onde pôr bits de colisão.

Regras combinadas com o usuário:
- O que pode mudar: ordem/sentido de passadas, tipo de movimento, aproximação, pontos no ar.
- Pontos com pistola ligada não mudam de posição; só o sentido pode inverter.
- Tudo é validado com a carroceria carregada (folga ≥ 50 mm).
- Robô × robô: 100 mm, TODOS os pares.
- Qualquer bit livre de 1 a 16.
- Meta = ciclo ideal HOME-to-HOME informado pelo usuário.
- A IA é o Claude Code do PC (sem chave de API).
- Cada sugestão tem a opção "Aplicar".

Fase A – motor de análise (CellCore):
- `CollisionGeometry.swift`: robô como cápsulas (pé→A1…A6→TCP, raios em `RobotGeometry.defaultRadii`); distância segmento-segmento; `ObstacleGrid` (carroceria como nuvem de pontos da superfície numa grade de 40 mm, 3,7 M triângulos → 124 mil pontos em ~1 s).
- `StationAnalysis.swift`:
  - `RobotTrack`, com `chains` = cadeia de CALLs de cada ponto (`EcoTalkRunResult.callChains`).
  - `conflicts` compara toda pose de A com toda pose de B na grade de 0,1 s, então pega risco mesmo em instantes diferentes. Agrupa em regiões, marca "simultâneo" e verifica proteção: A e B seguram o mesmo bit nos seus trechos.
  - `freePin`: ignora o SET Low de limpeza, porque o Home.tip zera 1…16.
  - `placement`: não corta passada; usa o nível mais fundo das CALLs em que início e fim ficam no mesmo programa; acusa `releasedInside`.
- `CycleAnalysis.swift`:
  - `breakdown`: aplicação/ar/espera/parado.
  - Sugestões de ciclo: `reversePasses` (bloco `LIN GUN(on,PTx) LIN… GUN(off,PTy) LIN`, invertido com disparos trocados), `airMoves` (tirar ponto no ar / LIN→PTP com o % de PTP do VEL em vigor, `ProgramPoint.ptpSpeed`).
  - Cada sugestão de ciclo simula o trecho antes e depois (`windowTime`) e verifica a folga à carroceria e os erros de cinemática.
  - Sugestões de colisão (`collisionSuggestions`): bit novo livre por região sem proteção. Fica "à mão" quando o robô está parado em HOME na região (bit não resolve; revisar o ponto) ou quando o bit seria liberado no meio do trecho. Também sugere "pedir o bit mais tarde" e "liberar mais cedo" a partir das esperas.
- `SourceEdit` (robô, programa, linha, op) e `EcoProgramEditor.apply` (de baixo para cima).
- Escalonador: o dono da zona é registrado no mesmo passo; um novo SET High do próprio dono não divide a zona.

Fase A – app:
- `StationAnalysisPanel.swift`:
  - `runAnalysis` roda em segundo plano (~5 s na 6010), com cache da grade da carroceria.
  - Painel "Análise da estação" (aba embaixo): ciclo por robô em barras com a meta, lista de sugestões e detalhe com as alterações.
  - "Ver na simulação" leva ao instante, à linha e ao caminho atual (vermelho) × proposto (verde), ou à esfera de risco.
  - "Aplicar" muda em memória, com desfazer, e recalcula. "Salvar alterações" grava. `scrub(to: 0)` antes de recalcular (antes começava da pose do instante selecionado).
- `StationEffect`: cada sugestão aplicável é reavaliada na ESTAÇÃO inteira (só o robô alterado é re-simulado e os bits reescalonados): ciclo por robô, ciclo da estação, colisões simultâneas e erros novos. Motivo: tirar P85 do R11 mudava o R21 por causa dos bits.
- Faixa "Análise IA": Analisar, meta de ciclo, critérios, desfazer e salvar.

Fase B – ponte com o Claude Code (`ClaudeBridge.swift`):
- `MCPServer`: HTTP em 127.0.0.1:8765/mcp, chave Bearer guardada em `UserDefaults mcpToken`, JSON-RPC (initialize, tools/list, tools/call, ping).
- Ferramentas: station_overview, run_analysis, list_suggestions, get_suggestion, apply_suggestion, undo_last_change, read_program, robot_trajectory, collision_report, simulate_edits (e se?) e propose_suggestion (entra no painel como "Sugestão do Claude").
- Painel "Claude" (aba embaixo): roda `claude -p … --mcp-config … --strict-mcp-config --allowedTools mcp__cellstudio --output-format stream-json`, com regras em `ClaudeChat.rules` e a conversa continuando com `--resume`.
- "Copiar comando MCP" gera `claude mcp add --transport http cellstudio http://127.0.0.1:8765/mcp --header "Authorization: Bearer …"`.
- Situação em 08/10:
  - O servidor e as ferramentas foram testados (via curl). simulate_edits mostrou que desativar `Main:10–11` do R11 (o teste do Collision1) leva a estação de 68,4 → 53,3 s.
  - O `claude -p` deste Mac responde "Credit balance is too low": a conta do Claude Code no terminal não tem plano (subscriptionType null). O chat do app precisa de plano ou créditos no Claude Code CLI. A sessão do app desktop pode usar o servidor depois do `claude mcp add`.
- Diagnóstico: `--analyze`, `--focus N`, `--apply`, `--effects`, `--mcp`, `--serve N`.

Pendências da IA: reordenar passadas (só inversão foi feita), OVERLAP/aproximação, raios das cápsulas por robô (hoje fixos), salvar a meta e os limites na estação, gráfico de ganhos acumulados.

### Fase 8: sessão limpa, módulos em abas, typelist (08/10/2026)
- Abertura do app: a última estação volta com os robôs em HOME (RHOME), sem robô ativo, sem programa e sem trajetória.
- Módulos em abas (`ProgramTabs.swift`):
  - `openTabs` guarda cada módulo aberto com as suas alterações e o seu desfazer. A barra fica acima de Código fonte/Dados; × fecha, perguntando se quer salvar.
  - Abrir um módulo ou trocar de aba chama `previewModule()`: o 3D mostra SÓ a trajetória daquele módulo, e "Simular programa" simula só ele.
  - `EcoTalkInterpreter.initialFrames` + `moduleEntryFrames`: o módulo aberto sozinho começa com o SETTOOL/SETOBJECT de quando é chamado (programa da estação, se for do mesmo projeto, senão o Main do projeto).
  - As sugestões da análise atualizam as abas abertas do mesmo programa.
- typelist.ini (`TypeListEntry`, `RobotBackup.typeList`, BCU1/typelists/typelist.ini; ignora cópias como typelist_nova.ini):
  - Faixa Simulação ▸ "Tipo em produção": escolher o tipo faz todos os robôs rodarem o Proj/Prog dele, cada um pelo próprio typelist (diferem um pouco entre robôs).
  - O tipo é salvo na estação (`typeNumber`).
- DELAY: conferido no motor e no app (módulo sozinho, Main, 4 robôs; ex.: `DELAY(10)` no início do Main do R12/R22 no Cuv_Track faz o robô começar a mover em 10,04 s). Não reproduzi falha; aguardando o caso do usuário.
- Diagnóstico: `--restore`, `--open ROBÔ:Projeto/Módulo` (repetível), `--type N`. O relatório traz ESTADO/SELECAO/RUN/DURACAO.

### Fase 8b: análise escolhe o programa e simula antes (08/10/2026)
- `AnalysisProgramPicker`, na faixa "Análise IA" e no painel, escolhe o programa da análise:
  - "Programas da estação (atual)";
  - um tipo do typelist.ini;
  - um projeto (Main do projeto em todos os robôs, `applyProject`).
- "Simular e analisar" (`simulateAndAnalyze`): para tudo, põe os robôs em HOME, gera a simulação conjunta com os programas escolhidos e roda a análise. A ferramenta MCP `run_analysis` usa o mesmo caminho.
- typelist: os tipos são identificados pela SEÇÃO (`TypeListEntry.section`), porque o TypNo se repete (Type6 e Type9 com TypNo=6 na 6010). A estação salva `typeKey`. O rótulo mostra "TypNo – Name (Description) → Proj/Prog".
- "Simular programa" de um módulo aberto roda só aquele módulo naquele robô (`simulateAllRobots = false`) e não muda mais o programa do robô na estação. Antes, simular o air_blast do R22 trocava o programa dele na estação.

### Fase 8c: riscos em instantes diferentes mais claros (08/10/2026)
- Pergunta do usuário: "por que risco se estão longe?". Resposta: a análise compara as posições de A e B em QUALQUER instante (o tempo real varia), então a maioria dos riscos é "em instantes diferentes" (ex.: R11 em 29,4 s e R21 em 34,3 s, os dois antebraços sob o centro da carroceria). O efeito na estação dá 0 s porque na simulação eles nunca estão lá juntos.
- `ConflictRegion` ganhou `closestATime/closestBTime/closestLinks`, e a esfera fica entre os elos que se aproximam.
- O título da sugestão diz "ao mesmo tempo" ou "R11 7,5 s × R21 18,2 s". Ao selecionar, cada robô aparece no instante em que fica mais perto do outro (`AnalysisSuggestion.poseTimes`).
- Ressalva: as cápsulas têm raio fixo (antebraço 100 mm), então "-38 mm" quer dizer cápsulas se tocando. Próximo passo: calibrar os raios pelas malhas HSF reais de cada elo.
- O relatório de diagnóstico lista "CONFLITO …" com instantes e elos.

### Fase 8d: riscos x bits existentes (08/10/2026)
- Revisão pedida pelo usuário: a análise considera os bits dos programas. Uma região é "protegida" quando os DOIS robôs seguram o MESMO bit durante os seus trechos (exclusão mútua); na Saga HEV, 20 das 53 regiões R11×R21 estão protegidas (Collision1–4).
- As outras são regiões em que os robôs passam pelo mesmo lugar protegidos por bits DIFERENTES ou sem bit. Ex.: R11 21–23 s com Collision3/4 × R21 47–52 s com Collision1/5: nenhum em comum, mas só se encontram com 25 s de atraso.
- `ConflictRegion.aPins/bPins` são os bits que cada um segura na região; `timeGap` é o atraso mínimo para se encontrarem.
- `StationAnalysis.timingTolerance` (UI "Variação ±5 s", salvo em UserDefaults `timingTolerance`) classifica cada região:
  - simultâneo → crítico;
  - atraso ≤ variação → risco;
  - acima → informação ("Só com atraso ≥ X s").
- O detalhe da sugestão lista os bits de cada robô e o atraso necessário.
- Saga HEV com ±5 s: 7 riscos e 28 informações. O 1º risco: R21 passa na região (17,6–19 s) sem bit nenhum, a 4 s do R11.
- O relatório de diagnóstico lista REGIAO (trechos, proteção) e ZONA (bits por robô).

### Fase 8e: bits do Main e bits compartilhados (08/10/2026)
- Os bits do Main entram na simulação: o interpretador executa o Main linha a linha, com as CALLs, e os SET/RECEIVE do Main viram ações como os dos módulos. Conferido na Saga HEV: R11 `Main_Hev:13–18` (Collision1 em volta do Cx_Estepe) e R21 `Main_Hev:10–21`.
- Os próprios módulos liberam bits pedidos no Main. Ex.: o R21 `Assoalho_sem_ECOJET_Hev:67` faz SET(Collision1, Low); a linha 148 libera Collision2/4; e ele só volta a pedir um bit na linha 461 (Collision6). Entre 148 e 461 o R21 trabalha sem bit.
- Os bits são por NOME na estação inteira (igual ao DXQ: um `CollisionBits` por `StationControlSimulation`). O Collision4 é usado pelo R11 ("R21-R11") e pelo R12 em `Rocker_panel` ("R11-R12"), e por isso o R11 espera 8 s pelo R12 em `Assoalho:17`.
- O detalhe do risco mostra, para cada robô, programa:linha da região, os bits que segura, o último bit liberado e o próximo pedido (desconsiderando o zeramento do Home).

### Fase 8f: ver o risco real × atraso e ir ao ponto (08/10/2026)
- `AnalysisSuggestion.riskPoints` (`RiskPoint`: robô, programa, linha, ponto, instante) = ponto de cada robô quando fica mais perto do outro.
- No detalhe do risco (no topo) e no menu do botão direito da lista:
  - "Posição real (R11/R21)" (`showRealPositions`): a estação inteira no instante do robô no ponto de risco, com a distância real entre o par.
  - "Mostrar colisão se um robô atrasar" (`showDelayedCollision`): cada robô no seu instante de aproximação, com o atraso necessário.
  - "Ir para o ponto de risco do R11/R21" / "Abrir R21 Assoalho…:214" (`goToRiskPoint`): abre o módulo do robô no editor, na linha, selecionada, e mostra a posição real.
- Ao selecionar um risco, abre na posição real. Antes abria já na pose de colisão.
- Exemplo na Saga HEV (R11×R21 -111 mm): na posição real, em 22,2 s, estão a 422 mm e, em 18,1 s, a 185 mm; a colisão acontece com 4,1 s de atraso.
- A avaliação na estação mostrou um bit sugerido que deixaria a estação +68,6 s (quase impasse): fica em vermelho e não deve ser aplicado.
- Diagnóstico: `--focus N --goto R21`, `--delayed`.

### Fase 9: Virtus.hsf (HSF exportado pelo próprio DXQ) (09/10/2026)
- `~/Desktop/6001/Virtus.hsf` (V23.00, 16 MB descompactado) falhava em "opcode 0xf1 em 98". O arquivo traz a cena do DXQ inteira: estilos de linha, fonte, segmentos robots/programs/simulation e marcadores (linhas, esferas, cilindros, texto). Correções em `HSF.swift`:
  - CRC de HSF 23 que faltava: `!` (seletividade, 1 byte), `H` (heurísticas, 2 bytes), `l` (linha, 1 byte);
  - `F` (fonte de texto): pulado por resync, como o `R`;
  - novos opcodes pulados com CRC: `0x1a` esfera (2º byte 01 = só centro e raio; 00 = + eixo e orientação, 24 bytes), `Q` policilindro (opções, n, pontos, nº de raios, raios, tampas), `x` texto (opções, posição, codificação, tamanho, caracteres, 1 byte);
  - `s` com marca que não é segmento: abre um segmento solto, sem anexar à cena, e continua.
- Resultado: 4.348 partes, 1.008.705 triângulos, 4058 × 1739 × 1261 mm, sem aviso. SAGA e elefante iguais a antes.

### Fase 10: estação/robôs como no DXQ e sem robô simplificado (15/10/2026)
Como funciona no DXQ (DirObjects/ViewModels, Hoops3DGraphic/AttachedContextMenus.cs):
- Projeto ▸ Estação ▸ Controle (robô) ▸ programas. A estação é só um título: Adicionar estação, Renomear, Excluir ("Station '{0}' will be removed from the project").
- O robô entra por "Adicionar controle" (pasta do backup do flash, .zip de backup, caminho online ou arrastando a pasta, com opção de copiar para o projeto). O controle tem Excluir e Recarregar.
- Vista 3D: "Remove robot from 3D" / "Show robot in 3D" (`CommandActionForRobot.RemoveFrom3DGraphicBackground`): o robô continua no projeto, só sai do 3D. Também há "Remove all robots from 3D".

No CellStudio (`StationManagement.swift`):
- `RobotSlot.hidden3D` (salvo na estação): "Remover da Vista 3D" / "Mostrar na Vista 3D" no menu do robô no explorador, no menu da estação (todos) e na faixa Vista 3D ▸ "Robôs no 3D".
  - O robô fora do 3D some da cena (raiz e trilho) e fica fora da simulação conjunta e da análise.
  - No explorador aparece cinza com "fora do 3D"; clicar nele não o torna ativo.
- Menu da estação: Adicionar robô (backup do flash)…, Renomear estação…, Nova estação… (também em Arquivo).
- `stationNameAuto`: o nome "Estação R11 / R21" só é gerado enquanto o usuário não escolhe um nome.
- Menu do robô: Recarregar backup, Mostrar backup no Finder, Excluir da estação… (confirma; não apaga arquivos; fecha as abas do robô).

Sem robô simplificado (`SceneController.build`): os nós de junta/elo ficam como esqueleto sem geometria. Só aparece o modelo real (HSF) com trilho, carro, peças e ferramenta reais; o nome do robô só aparece com o modelo carregado.
- Quando o modelo não carrega, `reportModelProblem` avisa em Mensagens com o motivo, e o explorador mostra "sem modelo 3D". Motivos possíveis: pasta 3DObjects não encontrada, tipo não identificado no catálogo, nenhum elo carregado (arquivo faltando/erro).
- Trilho sem modelo (sem backup ou sem EcoRailType no rpcsetup.ini): aviso "Trilho de Rxx não aparece…".
- Trilho criado depois de o robô sair do 3D já nasce escondido.
- Diagnóstico: `--hide R21`, `--no-models`. O relatório traz "ROBOS …".
- Observação (15/10): a sessão salva do usuário tinha os 4 robôs SEM backup ligado (backupPath vazio), por isso sem trilho nem programas.

### Fase 11: simulação múltipla rápida e edição de pontos (15/10/2026)
- Reprodução (`AppState.playbackTick`): relógio real (1× = tempo do robô), só o último instante de cada quadro vai para o 3D;
  lista de robôs/cursor/TCP publicados ~12×/s (`commitLive`); mensagens em lote; "Parar no erro" para no instante exato;
  efeitos da análise esperam o play. 41 s de ciclo a 25×: 3,4 s → 1,65 s (ideal 1,64 s).
- Guia **Transformação** (= "Transformation" do DXQ, `StartTabTransformationViewModel`), age nos POINTs locais dos comandos
  selecionados no editor: deslocar/girar por passo em Mundo/Objeto/Ferramenta/Eixos (+E1), Valores…, Restaurar coordenadas,
  Converter tipo (Axis/World/Object), copiar/colar orientação e E1, girar em torno de vetor, espelhar em plano, distância.
  Matemática em `CellCore/PointTransform.swift` (testes em CellCoreChecks); app em `PointEditing.swift` / `PointToolsViews.swift`.
  O tipo do ponto é mantido; Axis usa a inversa (fora de alcance → não altera e avisa). Espelhar/girar em vetor: só World/Object, como no DXQ.
  Espelho: posição e Z/X da pistola refletidos, Y = Z × X (o DXQ troca sinais na matriz; aqui a ferramenta fica sempre destra).
- Seleção no 3D: clique (sem arrastar) num ponto do caminho seleciona no editor o comando que o gerou (⌘/⇧ soma);
  ponto de subprograma ou de outro robô (simulação conjunta) abre o módulo na linha. Linhas selecionadas no editor
  deixam os pontos amarelos no 3D. `PickingSCNView` + `SceneController.pathPoint(at:)` (mais perto na tela, 10 px).
- Diagnóstico: `--points-selftest` e `--pick-selftest` (com `--open R:Proj/Mod`).

### Fase 12: visual do DXQ clonado (15/10/2026)
- Fonte: código descompilado do Hoops3DGraphic (AppearanceCfg, WindowBackgroundColor, H3DProgramStyle, H3DCommandDefinition,
  ProgramCfg, StateColors, Rendering), BAML do Shell (Themes.Office2013) e telas da ajuda (cores medidas por pixel).
- Vista 3D: fundo degradê (96,128,255) → branco; sem grade por padrão (o DXQ não tem; botão Grade continua);
  triedro X/Y/Z no canto inferior esquerdo (`AxisTriadOverlay`); TCP no canto superior esquerdo.
  Caminho selecionado verde (0,1,0), vários robôs uma cor cada; trecho com pistola ligada em tubo na cor do pincel
  (BrushColors, índice |pincel| mod 10); ponto = cone 10×20 mm na direção Z da ferramenta (Object cinza 0,75, Axis 0,3);
  cones de direção no meio dos trechos; seleção vermelha (SelectionColor); fora de alcance vermelho.
- Tema Office 2013: destaque #0072C6 (aba Arquivo, barra de status), seleção #CDE6F7, ribbon/painéis brancos,
  texto #444444, títulos de grupo #777777 (`enum DXQ` em Theme.swift).
- Ícones do DXQ: 955 PNG das pastas images/ das DLLs em `Resources/dxq` (build copia com cp -R).
  `DXQIcons.byTitle` (ribbon, pelo título do botão) e `DXQIcons.bySymbol` (explorador, barra do editor); sem ícone → símbolo do sistema.
- O snapshot de diagnóstico redesenha o triedro por cima do Metal.

### Fase 13: guias e menus do DXQ (15/10/2026)
- Guias no layout do DXQ (DXQRibbon.swift): Editor de programa, Ferramentas do editor, Vista 3D, Objetos 3D; ícones do DXQ (`dxq:nome`).
- Ferramentas (ProgramEditorTools.swift): Arrumar, Verificar/Verificar todos, Objeto-Objeto, Ferramenta-Ferramenta, Correção da posição zero,
  Espelhar/Transferir, Suavizar orientação (linear), copiar/colar diferença de orientação, medir distância, modos de renderização,
  chão, histórico de câmera, projeção, imprimir. Matemática em PointTransform (testada).
- Explorador (ExplorerFileOps.swift): menus da pasta Programas de teach, do projeto e do programa (adicionar, importar/exportar,
  renomear, substituir texto, excluir → Lixeira, recortar/copiar/colar, abrir/fechar todos, comparador, programas não usados).
- Desativados (sem como fazer offline): Ajustar ao robô (rcsdb01), RobCAD, EcoPaintJet, Distribuir programas, seções, editar modelo/estrutura.
- Pendente: conferir visualmente "Ferramentas do editor" e "Objetos 3D" (snapshot falhou por falta de janela), testar menus do explorador com arquivos reais.

## 6. Limitações e pendências

1. **Modelos 3D:** trilho, carro, peças e pistola estão feitos. A carroceria não existe no backup (importar HSF/STL em Objetos 3D), e os robôs em arquivo único (`RobotFileName`) ainda não são suportados.
2. **HSF:** faltam polilinhas compostas (`0x10`, só linhas), o opcode `D` (dicionário, no fim do arquivo) e alguns modelos raros (precision wrist, `rp_l_130i_bottom_v2`, Kawasaki `rs080n`). Também não lê robôs em arquivo único (`RobotFileName`, com segmentos `-kN`/`-axN`).
3. **EcoTalk:** o fluxo de controle e os bits de colisão estão feitos. Faltam TRIGGERFRAME, E/S que não são bits e funções de visão/PLC (assumidas no caminho normal).
4. **Comunicação online:** o DXQ usa OPC DA (DCOM), CommLib (RPC) e S7, que não existem no macOS. Hoje só há o robô virtual e um gateway TCP. Os próximos caminhos são OPC UA, S7 nativo ou um PC Windows servindo de ponte.
5. **Botão Salvar do editor:** grava direto nos `.tip/.tid` do backup aberto. Use uma cópia para preservar os originais. As edições ficam em memória (com desfazer) até o ⌘S.
6. O build gera um aviso de concorrência em `AppState.loadRobotModels` (não é erro).

## 7. Próximos passos sugeridos (em ordem)

1. **TRIGGERFRAME** (atraso/antecipação do GUN). O painel de bits já está feito (Fase 3b).
2. **Comunicação:** definir com a planta o que está disponível (OPC UA, S7 ou PC ponte).
3. **Cache dos modelos:** guardar as malhas já convertidas para abrir mais rápido e liberar o `_analise` (cerca de 3 GB).

## 8. Referências úteis no código descompilado

- Montagem e movimento 3D: `Hoops3DGraphic/…Model.Hoops_3D_Robots/H3DRobot.cs`, `H3DBaseLink.cs`, `H3DRobotConfigTo3DData.cs`
- Convenção de ângulos: `Common/…Maths/Matrix4x4.cs` (`ComputeKardanTcp`)
- DH: `DirObjects.Config/…Robot/DhParameters.cs`
- Catálogo do machinedata: `DirObjects/…Repositories/MachineDataFromCatalogLoader.cs`
- EcoTalk: `EcoTalk/…Models/EcoTalkTipParser.cs`, `EcoTalkTidParser.cs`
- Leitor HSF nativo (para dúvidas): Ghidra em `base_stream.dll`; funções `TK_Shell::Read`, `read_advanced`, `FUN_18004c300` (edgebreaker), `FUN_18004da90` (conectividade), `FUN_18004ebe0` (pontos)
