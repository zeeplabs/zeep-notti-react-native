# ADR-002: Ship iOS Rich Push via a Notification Service Extension Subspec (Mirroring OneSignal)

## Status

Accepted

## Context

Hoje o Notti SDK entrega notificação simples no iOS (título/corpo via `aps.alert`), sem imagem/vídeo/áudio anexado. A Apple exige um `UNNotificationServiceExtension` — um target de app extension separado, sandboxed — para baixar mídia e anexá-la antes da exibição (`mutable-content: 1` no payload dispara o SO a chamar a extension; ela monta um `UNNotificationAttachment` e chama `contentHandler`). Isso não é algo que um Turbo Module consiga injetar sozinho no projeto Xcode do app consumidor — é um target novo, com seu próprio ciclo de build/assinatura.

O OneSignal resolve isso publicando um pod/target auxiliar (`OneSignalNotificationServiceExtension`) que embute a lógica de download/anexo dentro do próprio SDK deles, versionado junto; o consumidor cria o target manualmente no Xcode e só cola uma linha de repasse (`OneSignalExtension.didReceiveNotificationExtensionRequest(...)`), sem reescrever lógica de attachment. Julio pediu explicitamente "exatamente como o OneSignal faz" — não documentação solta pro consumidor colar `UNNotificationAttachment` no próprio código.

Confirmado contra o backend real (`saas/zeep-notti`, `internal/providers/apns/apns.go:96-101`): o payload é montado manualmente via `apns2` (`map[string]any`), sem `mutable-content` setado e sem campo de URL de imagem hoje (`providers.Payload` só tem `Token`/`Title`/`Body`/`Data`). Ou seja, o contrato de payload pra rich push ainda não existe no backend — esta ADR cobre só o lado do SDK cliente (iOS); o backend precisa de uma mudança própria (fora deste repo) pra emitir `mutable-content`+URL de imagem.

## Decision

Vamos publicar um **subspec CocoaPods separado** (`Notti/NotificationServiceExtension`) dentro do mesmo `Notti.podspec`, contendo uma classe Swift pura (sem `import React`/dependência de TurboModule) que expõe um helper estático — `NottiNotificationServiceExtension.didReceive(_:withContentHandler:)` — encapsulando toda a lógica de baixar o anexo e montar o `UNMutableNotificationContent`. Documentação (README + guia dedicado) instrui o consumidor a:

1. Criar manualmente o target `NottiNotificationServiceExtension` no Xcode (`File > New > Target > Notification Service Extension`), mesmo deployment target do app principal.
2. Adicionar `pod 'Notti/NotificationServiceExtension'` num target próprio no Podfile (sem puxar `React-Core`/dependências RN — a extension não roda React Native).
3. Reduzir o `NotificationService.swift` gerado a uma chamada de repasse pro helper do Notti.
4. Configurar App Group (`group.<bundle-id>.notti`) em ambos os targets, se/quando alguma feature futura precisar compartilhar estado entre extension e app principal (não estritamente necessário só pro attachment, mas alinhado ao padrão OneSignal e reservado pra paridade).

Payload: reservamos a chave de nível superior `"image"` (string, URL) como o contrato do attachment — sibling de `aps`, no mesmo padrão que `Data` já é hoje (`providers.Payload.Data` vira campos soltos no topo). `mutable-content: 1` é setado pelo backend sempre que `image` estiver presente. Este SDK cliente já trata `mutable-content`/`mutable_content` como chave de transporte interna (`NottiNotificationParsing.swift`, `internalKeys`), então não precisa de mudança nesse parser — só o helper da extension precisa ler `image` do `userInfo`.

Alternativas descartadas:
- **Só documentação, sem pacote**: mais rápido, mas quebra o contrato de SDK — bug/mudança de payload vira "atualiza o código que você colou" em vez de bump de versão de lib. Diverge do padrão real do OneSignal, que foi o pedido explícito.
- **Framework SPM separado em vez de subspec do mesmo Podspec**: mais isolamento, mas exige manter dois manifestos de versão sincronizados (Podspec do módulo RN + Package.swift da extension) — risco maior de drift de versão que o próprio OneSignal já documenta como armadilha. Subspec único resolve isso de graça (mesma tag de release para ambos).

## Consequences

**Fica mais fácil:**
- Consumidor ganha rich push com poucas linhas de setup (mesmo modelo mental do OneSignal, que o time já conhece).
- Lógica de attachment é testável e versionada dentro do próprio Notti, não copiada/colada no app consumidor.
- Nenhuma mudança no parser de payload existente (`mutable-content` já é tratado como transporte interno).

**Fica mais difícil / novos riscos:**
- Subspec sem dependência de React precisa de disciplina de build (`s.source_files` da subspec não pode acidentalmente puxar arquivo que importe `React`/`ReactCommon`, ou o link da extension quebra).
- Setup ainda exige passo manual no Xcode (target + Podfile + capability) — não é zero-config; documentação tem que ser tão precisa quanto a do OneSignal pra não gerar suporte.
- Contrato de payload (`image` + `mutable-content`) depende de mudança no backend `zeep-notti` (fora deste repo) — este SDK fica pronto, mas a feature só funciona ponta a ponta depois que o backend também implementar. Bloqueador rastreado como item separado, não parte desta ADR.
- NSE não roda no Simulador (Xcode 11.4+) — QA da feature exige device físico.
- Payload APNs limitado a 4KB e a extension tem ~30s de execução — imagens grandes/lentas de baixar podem estourar o timeout e cair no fallback sem attachment (comportamento esperado, mas precisa estar documentado pro consumidor não achar que é bug do Notti).

## Links

- ADR-001 (`001-expose-device-id-getter-and-change-event.md`) — mesmo espírito de espelhar deliberadamente o padrão OneSignal em vez de inventar shape próprio.
- Apple: [Modifying and Presenting Notifications](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/ModifyingNotifications.html), [Creating the Remote Notification Payload](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/CreatingtheNotificationPayload.html)
- OneSignal: [iOS SDK Setup](https://documentation.onesignal.com/docs/ios-sdk-setup)
- Backend: `saas/zeep-notti/internal/providers/apns/apns.go:96-101`, `internal/providers/provider.go:21-26` (confirmado sem `mutable-content`/campo de imagem hoje — mudança de contrato necessária lá, fora do escopo deste repo).
