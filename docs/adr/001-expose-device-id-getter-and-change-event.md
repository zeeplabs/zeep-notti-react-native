# ADR-001: Expor Device ID interno via getter cacheado e evento de mudança

## Status

Accepted

## Contexto

O SDK Notti hoje (`src/index.tsx`, `src/NativeNotti.ts`) não expõe nenhum identificador interno do device para o app consumidor. `initialize()` e `login(externalUserId)` são `void` — não retornam nem emitem o ID que o backend Notti usa internamente para rotear notificações para aquele device.

Isso foi identificado ao integrar o SDK no app da Starbem para substituir o OneSignal. No OneSignal, o SDK retorna o `OneSignal ID` (via `OneSignal.User.pushSubscription.id`, getter síncrono cacheado) e o app salva esse ID vinculado ao usuário no próprio backend. Sem um equivalente no Notti, o app consumidor não tem como:

- persistir localmente o vínculo usuário ↔ device no seu próprio backend;
- depurar problemas de entrega de notificação (suporte precisa de um ID rastreável);
- detectar quando o ID muda (reinstall, troca de device, revogação) para atualizar o vínculo salvo.

O ID é atribuído de forma assíncrona (depende de round-trip com o backend Notti após `initialize`/`login`), então não pode ser garantido disponível de forma síncrona logo na primeira chamada.

## Decisão

Adicionar ao Spec (`NativeNotti.ts`) e à facade pública (`index.tsx`):

- `getDeviceId(): string | null` — getter síncrono, lê valor cacheado nativamente. Retorna `null` até o ID ser atribuído pelo backend Notti.
- `onDeviceIdChanged` — `CodegenTypes.EventEmitter<string>`, exposto via `Notti.addEventListener('deviceIdChanged', callback)`, disparado quando o ID é atribuído pela primeira vez ou atualizado (reinstall, troca de device, revogação/renovação pelo backend).

Padrão espelha deliberadamente `OneSignal.User.pushSubscription.id` + `addObserver`/`onSubscriptionChange`, já validado em produção por outro SDK de push e já familiar para quem está migrando do OneSignal.

Alternativas descartadas:
- **`login()` retornando `Promise<string>`**: acopla a confirmação do ID ao fluxo de login, mas o ID pode mudar depois do login (revogação/reinstall) sem novo `login()` — não cobre atualização.
- **Só getter, sem evento**: força o app consumidor a fazer polling para saber quando o ID passa de `null` para um valor — pior ergonomia, sem ganho de simplicidade real do lado nativo.

## Consequências

- App consumidor (Starbem) pode persistir o Device ID Notti vinculado ao usuário assim que disponível, sem polling.
- Suporte/debug ganha um identificador rastreável para correlacionar com o backend Notti.
- Native (Android/iOS) precisa implementar cache do valor e emitir o evento nas transições relevantes (atribuição inicial, reinstall, revogação) — trabalho adicional no lado nativo, ainda não escopado.
- Contrato público do SDK cresce (novo método + novo evento), exigindo bump de versão conforme semver do pacote.
- `getDeviceId()` pode retornar `null` por um período indeterminado após `initialize()` — consumidores precisam tratar esse estado explicitamente (não assumir valor disponível de imediato).

## Links

- Discussão original: integração do SDK Notti no app Starbem em substituição ao OneSignal.
