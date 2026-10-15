# 09. Revisão técnica e plano de melhorias

> Revisão feita em 26/09/2026 sobre o código completo (SignalCore, SignalUI, SignalApp, testes, docs e projeto Xcode).
> Objetivo do produto: escanear casas inteiras com LiDAR e encontrar a melhor posição para o roteador e os satélites mesh, com a maior cobertura possível.
> Os itens de App Store (privacy manifest, launch screen, metadados) ficam para uma etapa posterior e não fazem parte deste plano.

Severidade: **P0** dá resultado errado ou bloqueia o objetivo; **P1** afeta muito a experiência ou a confiança; **P2** qualidade e manutenção; **P3** polimento.

---

## 1. Como a revisão foi verificada

- Leitura de todo o código Swift (~6.000 linhas), shader Metal, docs, `project.yml` e `Package.swift`.
- Build para o simulador iOS: passou sem warnings de código.
- 10 XCTests passam. O runner `SignalTestRunner` dá 15/16: o Test 14 (exportar e reimportar JSON) falha, apesar de o `TRACKING.md` dizer 16/16.
- Scripts isolados confirmaram os comportamentos e mediram a performance (release, Mac):
  - No estado padrão da demo, o caminho direto até o probe dá −103,2 dBm, mas o inspector mostra −54,6 dBm por causa de uma reflexão pela porta do quarto.
  - A cobertura do mesmo estado sai 76,8% (heatmap), 79,9% (grade de 0,5 m) e 92,6% (com reflexões).
  - Dois armários metálicos no mesmo raio contam 35 dB em vez de ~70.
  - Um raio pela junção de duas paredes de betão passa com 0 dB; um roteador em cima de uma parede também.
  - Heatmap 112×80: 0,56 ms (demo) e 2,4 ms (160 segmentos). Cada evento de arrasto emite 13 `objectWillChange`; cada troca de banda, 15.
  - Otimizador: 36 ms na demo; 864 ms numa casa de 24 × 16 m, melhorando só de 55,9% para 56,1%.
  - `saveScan`: 2,6 ms e 83 KB por gravação, um backup novo a cada save, sem limpeza.
  - Depois de `deleteSavedScan()`, `loadLatestScan()` restaura o scan a partir do backup.

## 2. Achados

### 2.1 Precisão da simulação e do scan

| # | Sev. | Problema | Correção planejada |
|---|---|---|---|
| A1 | P0 | Portas, janelas e aberturas do RoomPlan são adicionadas por cima das paredes, sem recortá-las. O sinal não passa pelas portas; `opening` cai no `default` e vira parede; janelas somam vidro + parede. | Cortar a parede-mãe no intervalo de cada vão (por `parentIdentifier` ou sobreposição geométrica) e preencher com o material do vão (aberta 0 dB, fechada madeira, janela vidro). |
| A2 | P0 | Objetos do RoomPlan são ignorados pelo conversor; rotação ignorada; `objId` é categoria (máscara de bits) e não instância. | Converter objetos relevantes em caixas rotacionadas com ID por instância; deduplicação por instância no motor. |
| A3 | P0 | Um cômodo por sessão, sem casa inteira nem andares; polígonos de cômodo por heurística gulosa. | Scan multi-cômodo com o mesmo `ARSession` e `StructureBuilder`; usar `floors`, `sections` e `story` do RoomPlan; motor com andares e perda de laje. |
| A4 | P0 | Cobertura calculada sobre o retângulo (inclui margem e área externa). | Máscara de interior (polígonos dos pisos) usada por heatmap, cobertura, otimizador e probe. |
| A5 | P0 | Heatmap e cobertura só com caminho direto; inspector com reflexões; três grades de cobertura diferentes. | Um único campo de sinal (direto + reflexões), usado por mapa, cobertura, badges, probe e otimizador (verificação final). |
| A6 | P1 | Classificação de materiais: toda parede que toca o perímetro vira tijolo; regra de espessura nunca dispara; janelas sempre Low-E; interior sempre drywall. | Parede externa detectada pelo lado de fora do polígono; perfil de construção (alvenaria, drywall, betão); vidro comum por padrão; catálogo ampliado. |
| A7 | P1 | Epsilon relativo nas interseções: vazamento em junções e AP sobre parede sem perda. | Epsilon absoluto em metros, pontas inclusivas com deduplicação de cruzamentos coincidentes, AP empurrado para fora de paredes e objetos. |
| A8 | P1 | Backhaul modelado como −10 dB de potência; sempre 5 GHz; sem cabo nem encadeamento. | Backhaul como limite de vazão; árvore de backhaul (roteador ou outro satélite); opção cabo; banda configurável; linha de backhaul no mapa. |
| A9 | P1 | Ruído fixo −95 dBm para todas as larguras de canal; "velocidade" é taxa PHY; rótulo "ITU-R P.1238" incorreto. | Ruído por largura de canal; tabela MCS por padrão Wi-Fi, largura e fluxos; vazão real estimada limitada por backhaul e plano de internet; rótulo "modelo multi-parede". |
| A10 | P2 | Três implementações da física (motor, gerador, shader) que já divergem. | Um único núcleo; remover o renderer Metal morto e o `.metal` duplicado. |
| A11 | P3 | Perna 2 da reflexão sem `continue` após o corte de 22 dB. | Corrigido no novo núcleo. |
| A12 | P2 | Sombras com bordas perfeitas (só caminho direto). | Reflexões no campo; isolinhas nos limiares. |

### 2.2 Encontrar o melhor spot

| # | Sev. | Problema | Correção planejada |
|---|---|---|---|
| B1 | P0 | Otimizador só move o roteador e ignora satélites e backhaul. | Otimização conjunta roteador + N satélites com restrição de backhaul e recomendação de quantos nós são necessários. |
| B2 | P0 | Aceita posições dentro de objetos e fora da casa. | Candidatos só no interior, fora de objetos e a uma distância mínima das paredes. |
| B3 | P1 | Objetivo binário, só direto, só na banda selecionada. | Objetivo contínuo ponderado por cômodo, na banda limitante; verificação final com o modelo completo. |
| B4 | P1 | Resultado aplicado sem prévia nem desfazer; resumo em inglês; não salva; sem cancelar; dois botões diferentes. | Folha única com opções, progresso, cancelar, prévia antes/depois, Aplicar/Descartar e Desfazer. |
| B5 | P1 | Sem restrições reais (fibra, tomada). | "Roteador fixo" (não mover) e posição marcada durante o scan. |

### 2.3 Cores e limiares

| # | Sev. | Problema | Correção planejada |
|---|---|---|---|
| C1 | P1 | Seis escalas diferentes (heatmap CPU, Metal, legenda, `SignalGrade`, `RoomZone`, raio do probe). | Tipo único `SignalScale` com limiares, cores e textos, usado em todo o app. |
| C2 | P1 | Paleta vermelho→verde ruim para daltonismo; rótulos "Gigabit"/"Ultra 4K" enganosos. | Paleta alternativa acessível; isolinhas em −67/−75 dBm; rótulos pelo que o usuário consegue fazer. |

### 2.4 Comandos quebrados ou inacessíveis

| # | Sev. | Problema | Correção planejada |
|---|---|---|---|
| D1 | P0 | Editar material de parede é impossível (`selectedWallId` nunca é atribuído). | Toque na parede no mapa 2D; editor com aplicar em lote. |
| D2 | P0 | Satélites não podem ser removidos. | Editor de AP com remover, renomear, potência, backhaul e fixar. |
| D3 | P0 | Apagar scan não funciona (restaurado do backup; card continua). | Projetos múltiplos; apagar remove o projeto e os seus backups, com confirmação. |
| D4 | P1 | "Abrir mapa salvo" abre a demo se ela foi vista antes. | Lista de projetos; demo separada. |
| D5 | P1 | Modo AR simulado. | AR real com `ARWorldMap` salvo no fim do scan, heatmap no chão e probe ao vivo. |
| D6 | P1 | Arrasto falha no modo 3D (perspectiva só no desenho) e `draggingApId` fica preso em cancelamento. | Edição apenas em 2D (3D só visualização); `@GestureState`. |
| D7 | P1 | Partilha envia String; sem importação; formatos de export/import incompatíveis; exportador fixa 14 × 10 m; portas abertas viram drywall ao importar. | Arquivo `.signalsim` (Transferable + UTType), importação por `fileImporter`/`onOpenURL`, formato único do projeto; exportador web corrigido. |
| D8 | P1 | "Novo Scan" substitui o único projeto; corrida no cancelamento pode sobrescrever o mapa. | Cada scan cria um projeto; controlador de scan com referência direta à sessão. |
| D9 | P1 | Sem checagem de LiDAR nem de permissão da câmera. | `RoomCaptureSession.isSupported` e estado da câmera antes do scan. |
| D10 | P2 | Promessa de backups no app Arquivos falsa. | Chaves de partilha de arquivos no `project.yml`. |
| D11 | P3 | Toggle "Reflexões" só afetava o probe; `showZoneBadges` morto; progresso falso. | Removidos ou corrigidos. |

### 2.5 Performance

| # | Sev. | Problema | Correção planejada |
|---|---|---|---|
| E1 | P1 | Invalidação do SwiftUI: `ObservableObject` com ~45 `@Published`; zoom/pan no view model; mutação elemento a elemento. | `@Observable`, estado de gesto local, atribuições únicas. |
| E2 | P2 | Trabalho no `body`: polígonos recalculados, disco lido na tela inicial. | Valores derivados cacheados no modelo. |
| E3 | P1 | Gravação síncrona a cada fim de arrasto, backups sem limite. | Actor de persistência em background, debounce, retenção de 5 backups, JSON compacto. |
| E4 | P2 | Otimizador sem cancelar, alocações no loop quente, sem paralelismo. | Matriz candidatos × pontos com caminho rápido sem alocação e `concurrentPerform`. |
| E5 | P2 | Launch síncrono; logger abre o arquivo a cada linha. | Carregamento assíncrono; `os.Logger` + buffer. |

### 2.6 UI/UX, acessibilidade e idioma

| # | Sev. | Problema | Correção planejada |
|---|---|---|---|
| F1 | P1 | Falta o fluxo: marcar roteador, configurar equipamento, resultado por cômodo. | Botão "Estou ao lado do roteador" no scan; folha de equipamento; resumo por cômodo. |
| F2 | P1 | Paddings fixos; sheet com altura estimada; botões que quebram linha; HUD inclinado no 3D. | `NavigationStack` + `safeAreaInset`; HUD fora do container 3D. |
| F3 | P1 | Alvos < 44 pt, fontes fixas, sem rótulos de acessibilidade, canvas invisível ao VoiceOver, sem Reduzir Movimento, haptics excessivos. | Estilos de texto, 44 pt, rótulos e ações de acessibilidade, `accessibilityReduceMotion`, `sensoryFeedback` só em confirmações. |
| F4 | P1 | Inglês misturado; região de desenvolvimento `en` (orientação do RoomPlan em inglês); números com ponto. | (Histórico.) Em 27/09/2026 a decisão passou a ser app somente em inglês, sem traduções. |
| F5 | P2 | Jargão (RSSI, SNR, FSPL), coordenadas no cabeçalho, nomes de parede com material antigo, diagnóstico na UI principal, copy exagerada. | Linguagem simples, detalhes técnicos em "Detalhes", diagnóstico no menu, copy honesta. |
| F6 | P3 | APIs depreciadas; `ForEach` por índice; dois indicadores de arraste. | Atualizadas. |

### 2.7 Arquitetura e testes

| # | Sev. | Problema | Correção planejada |
|---|---|---|---|
| G1 | P2 | View model com 880 linhas misturando tudo. | Núcleo puro (motor, campo, otimizador, conversor), store de projetos, view model orquestrador. |
| G2 | P2 | Flags de comando via `updateUIView`. | Controlador de scan. |
| G3 | P2 | Números mágicos, `crossingLoss` indexado por posição. | Tipos explícitos, decodificação segura e compatível. |
| G4 | P2 | Singletons; testes gravam no Documents real. | Diretório injetável. |
| G5 | P2 | `Package.swift` sem strict concurrency; `.pbxproj` divergente do `project.yml`; Swift 6 inativo. | Swift 6 nos dois; projeto regenerado pelo `project.yml`. |
| G6 | P2 | Testes vazios (13, 15, 16) e ausentes onde estão os bugs. | Testes de conversor, máscara, otimizador, persistência, escala, taxa e partilha. |
| G7 | P2 | Docs afirmam recursos inexistentes. | README, TRACKING e docs atualizados. |

## 3. Decisões de implementação

- **Modelo de propagação:** multi-parede (espaço livre n=2 + perda por parede com fator oblíquo limitado a 2×) com reflexões especulares de um salto. Contribuições 15 dB abaixo do caminho direto são descartadas (efeito < 0,14 dB). Entre andares: distância 3D, paredes do andar do receptor e perda de laje por andar.
- **Melhor servidor:** o cliente associa ao AP com melhor sinal (máximo), nunca soma de potências entre APs.
- **Escala de sinal (padrão):** excelente ≥ −55, bom ≥ −67 (limiar de cobertura, configurável), razoável ≥ −75, fraco ≥ −85, sem sinal < −85 dBm.
- **Taxa e vazão:** ruído = −174 + 10·log10(largura) + 7 dB; MCS por SNR; vazão real ≈ 60% da taxa PHY, limitada pelo backhaul e pelo plano de internet.
- **Idioma:** o app é somente em inglês, sem traduções.
- **Formato de arquivo:** `.signalsim` = JSON do projeto (versão de esquema 2), com migração dos arquivos antigos.
- **3D:** apenas visualização; edição no 2D.

## 4. Estado (27/09/2026)

Todos os itens abaixo foram implementados. A verificação automática cobre o núcleo (45 testes); o scan, o AR e os gestos precisam de validação no iPhone (ver `TRACKING.md`).

## 5. Checklist

- [x] A1–A12 precisão (A12: reflexões no mapa e isolinhas; sem modelo de difração)
- [x] B1–B5 otimizador
- [x] C1–C2 escala única
- [x] D1–D11 comandos (D7: o simulador web ainda não tem importador; o app exporta no formato dele)
- [x] E1–E5 performance
- [x] F1–F6 UI/UX
- [x] G1–G7 arquitetura e testes

## 5b. Segunda rodada (27/09/2026)

- **Cômodos pretos:** `RoomRegionDetector` encontra as regiões fechadas pelas paredes (portas e janelas contam como barreira; o exterior é preenchido a partir da borda). Completa os pisos do RoomPlan e reconstrói os cômodos de projetos antigos.
- **Reparo de projetos antigos (esquema 3):** `ProjectRepair` recorta portas sobrepostas às paredes, reclassifica materiais (externa/interna), troca o Low-E antigo das janelas por vidro comum e limpa nomes de parede. Validado com um projeto legado sintético derivado do apartamento demo (`RealScanTests`): de 3 polígonos quebrados para 8 cômodos, todos com mapa.
- **Cores do sinal:** escala estendida até −35 dBm, suavização visual de 0,6 m dentro de cada cômodo, expoente de distância 2,5 e 3 dB de margem do aparelho quando não há calibração.
- **UI refeita** a partir de protótipos gerados (mapa, tela inicial, detalhes do ponto): mapa em tela cheia, cabeçalho e banda flutuantes, trilho de controles, cartão de resumo, medidor de sinal, miniaturas com anel de cobertura. Testado no simulador com toques reais (AXe): abrir projeto, trocar banda, arrastar roteador, desfazer, otimizar/aplicar, adicionar satélite, 3D.

## 6. Onde está cada correção

| Item | Arquivo |
|---|---|
| Motor único, tolerâncias, deduplicação, reflexões, andares | `Sources/SignalCore/Engine/RFPropagationEngine.swift` |
| Campo de sinal, máscara, cobertura por cômodo, isolinhas, heatmap | `Sources/SignalCore/Engine/SignalField.swift` |
| Taxa e vazão | `Sources/SignalCore/Engine/LinkRateModel.swift` |
| Backhaul | `Sources/SignalCore/Engine/BackhaulPlanner.swift` |
| Otimizador | `Sources/SignalCore/Engine/PlacementOptimizer.swift` |
| Calibração | `Sources/SignalCore/Engine/Calibrator.swift` |
| Conversor RoomPlan | `Sources/SignalCore/Converters/RoomPlanConverter.swift` |
| Escala de sinal | `Sources/SignalCore/Models/SignalScale.swift` |
| Projetos e persistência | `Sources/SignalCore/Models/FloorplanProject.swift`, `Sources/SignalCore/Serialization/ProjectStore.swift` |
| View model | `Sources/SignalCore/ViewModels/FloorplanViewModel.swift` |
| Scan multi-cômodo | `Sources/SignalUI/Scan/` |
| Mapa, legenda, gestos, acessibilidade | `Sources/SignalUI/Map/` |
| Folhas (inspector, equipamento, otimizador, calibração) | `Sources/SignalUI/Sheets/` |
| AR | `Sources/SignalUI/AR/ARWalkthroughView.swift` |
| Relatório PDF | `Sources/SignalUI/Report/ReportRenderer.swift` |
| Idioma | Texto em inglês no código-fonte (sem String Catalog) |

## 7. Idioma

Decisão de 27/09/2026: o app é somente em inglês, sem traduções. O String Catalog pt-BR/pt-PT foi removido.
