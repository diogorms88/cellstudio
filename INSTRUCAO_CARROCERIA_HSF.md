# Tarefa: importar carroceria (.hsf) na aba "Objetos 3D" do CellStudio

## Contexto (leia antes)

- Projeto: app macOS em Swift (SwiftUI + SceneKit) que recria o DXQ3D.onsite da Dürr. Pasta `~/Desktop/DXQ Portavel/CellStudio/`.
- Leia `CONTINUIDADE.md` (visão geral) e `README.md`.
- Build: `./build.sh` (gera `build/CellStudio.app`). Testes: `./build.sh test`, todos devem continuar passando. **Não usar SwiftPM nem Xcode**: o build é `swiftc` direto, via `build.sh`.
- **Já existe um leitor HSF completo e testado:** `Sources/CellCore/HSF.swift`.
  - `HSF.load(url) -> [HSFPart]`.
  - Cada `HSFPart` tem `positions` (**metros**), `indices` (triângulos) e `color` (0…1, opcional).
  - Já lida com compressão edgebreaker, múltiplos blocos zlib, includes e instâncias.
  - `HSF.lastWarning` traz o motivo quando a leitura foi parcial.
- Unidades no app: **mm**, eixo **Z para cima**. A cena usa um nó `world` que já converte mm → m.

## Objetivo

Na aba **Objetos 3D**, o usuário importa um arquivo **`.hsf`** de carroceria (a peça que o robô trabalha). Ela aparece na Vista 3D na posição correta da estação e pode ser usada como alvo da simulação de pintura ou vedação.

## Onde mexer

1. **`Sources/CellStudio/AppState.swift`**, função `static func loadMesh(_ url: URL) throws -> Mesh`.
   - Hoje o `case "hsf"` lança "ainda não são suportados". Substituir por:
     - `let parts = try HSF.load(url)`;
     - juntar todas as partes num único `Mesh`: concatenar `positions` multiplicadas por **1000** (m → mm) e somar o deslocamento de vértices aos `indices` de cada parte;
     - se não houver triângulos, lançar erro com `HSF.lastWarning`.
   - Construir `Mesh(positions:indices:)`. As normais são calculadas no init (`Sources/CellCore/Paint.swift`).
   - Opcional, e melhor: guardar as cores das partes (`HSFPart.color`) num array por vértice ou agrupar por cor, para a carroceria não ficar toda cinza. Se fizer isso, adaptar `SceneController.setPart`. Ver `SceneController.meshNode(_:)`, que já agrupa `HSFPart` por cor.
2. **`importPart(_ url:)`** no mesmo arquivo:
   - Hoje centraliza a peça na frente do robô (`offset = Pose(x: 1700 …)`). **Para carroceria isso está errado.**
   - Coloque a peça no **sistema de coordenadas do objeto (OBJECT) do programa**, como o DXQ faz:
     - os objetos estão no `_globalvars.tid` de cada robô, já lidos em `RobotBackup.systemData` (tipo `OBJECT`, 6 números X, Y, Z, A, B, C em mm/graus, convenção Dürr R = Rz(C)·Ry(B)·Rx(A); usar `Pose(x:y:z:a:b:c:)`);
     - exemplo do R11: `S202 : OBJECT := (1498.349, 16.217, 2373.535, -0.189, 0.1, -179.775)`.
   - Ao importar `.hsf`, perguntar (sheet ou `Picker`) **qual OBJECT** usar, listando os OBJECTs de todos os robôs carregados (`app.robots[].backup?.systemData`, filtrando `type == "OBJECT"`). O padrão é o OBJECT do último `SETOBJECT` do programa aberto, se existir.
   - Também oferecer "Origem da estação (0,0,0)".
   - `offset` = a Pose escolhida.
   - Se o usuário não tiver backup aberto, cair no comportamento atual.
3. **`Sources/CellStudio/MainWindow.swift`**:
   - no `objectsTab`, botão "Importar peça": incluir `"hsf"` na lista de extensões do `openFile([...])`;
   - adicionar um botão grande **"Importar carroceria"** (ícone `car.side`) que abre só `.hsf`/`.stl` e chama o fluxo com escolha de OBJECT;
   - fazer o mesmo no `FileMenu` e no menu do `App.swift` ("Importar peça 3D…").
4. **`Sources/CellStudio/Explorer.swift`**, `PropertiesPanel.partProps`:
   - mostrar também o nome do OBJECT usado;
   - permitir trocar o OBJECT (Picker) além do `PoseEditor` que já existe.
   - Guardar o nome do objeto em `Part` (novo campo opcional `objectName: String?`).
5. **`StationFile`** (topo do `AppState.swift`): salvar `objectName` em `PartRef` (opcional, para não quebrar arquivos antigos).

## Cuidados

- **Desempenho:** carrocerias podem ter milhões de triângulos.
  - Ler o HSF numa fila de fundo (`DispatchQueue.global`) e voltar para a main para `parts.append` e `scene.setPart`, como em `loadRobotModels()`.
  - Mostrar "Carregando…" em `info(...)`.
- **Simulação de pintura:** `ensureSimulator()` refina a malha (`refined(maxEdge:)`). Para carroceria grande, usar `refineEdge` maior (ex.: 30 mm) ou avisar quando passar de ~2 milhões de vértices.
- Não mexer no leitor `HSF.swift` a menos que um arquivo falhe. Se falhar, registrar o `HSF.lastWarning` na janela Mensagens e manter a geometria parcial.
- Escala: se a caixa envolvente resultante for menor que ~10 mm ou maior que ~20 m, avisar (pode ser arquivo em outra unidade).
- Manter o estilo do código: português nos textos e comentários, sem dependências externas.

## Como testar

1. `./build.sh && ./build.sh test`.
2. Abrir o app, **Arquivo ▸ Abrir backup de robô…** → `R11` e `R22` (em `~/Desktop/DXQ Portavel/`).
3. **Objetos 3D ▸ Importar carroceria** → escolher um `.hsf` e o OBJECT `S202`.
4. Abrir o programa `s202_new/under` (duplo clique no Explorador) e iniciar a simulação. A trajetória do cordão (laranja) deve passar sobre a carroceria (a parte de baixo, em ~2,4 m de altura).
5. Captura sem interface:

   ```bash
   build/CellStudio.app/Contents/MacOS/CellStudio --snapshot /tmp/x.png --backup ../R11 --backup ../R22 --program under --seek 0.45
   ```

   Se quiser, adicionar um argumento `--part arquivo.hsf --object S202` ao modo de diagnóstico em `App.swift`.
6. Para testar sem carroceria real, qualquer `.hsf` de `~/Desktop/DXQ Portavel/_analise/inst/3DObjects/` serve (ex.: uma ferramenta) para validar o fluxo.

## Ao terminar

- Atualizar `CONTINUIDADE.md` (seção 5) com o que foi feito.
- Rodar `./build.sh test`.
