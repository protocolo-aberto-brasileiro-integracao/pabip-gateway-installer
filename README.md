# pabip-gateway-installer

Um script só, pra subir uma instância nova do pabip-gateway sem precisar clonar repositório, instalar dependência nenhuma além de Docker e responder umas perguntas no terminal.

O [pabip-gateway](https://github.com/protocolo-aberto-brasileiro-integracao/pabip-gateway) é a implementação de referência do protocolo PABIP — a ponte self-hosted entre quem produz eventos de analítico de imagem (Ente Privado, câmeras/sensores) e quem consome (sistema do Ente Público, via callback, fila ou banco). Este repositório cobre só o instalador; o código do gateway em si vive no repositório linkado acima.

## Pra quem é isso

Pra quem já decidiu subir uma instância e só quer o caminho mais curto até ela estar respondendo. Se você ainda está avaliando infraestrutura, converse antes com quem cuida disso na sua organização — o gateway não prescreve plataforma de hospedagem, mas exige Postgres, rede isolada pra porta administrativa e controle sobre TLS, o que já elimina bastante opção de PaaS genérico.

## Como usar

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/protocolo-aberto-brasileiro-integracao/pabip-gateway-installer/main/bootstrap.sh)"
```

Só isso. O único pré-requisito é ter Docker instalado e o daemon rodando. `openssl` também precisa estar disponível (já vem por padrão em quase toda distro/macOS).

Se preferir revisar o script antes de rodar — recomendado, principalmente antes de rodar algo via curl — baixe e leia:

```bash
curl -fsSL https://raw.githubusercontent.com/protocolo-aberto-brasileiro-integracao/pabip-gateway-installer/main/bootstrap.sh -o bootstrap.sh
less bootstrap.sh
bash bootstrap.sh
```

## O que o script pergunta e o que ele faz

1. Nome do Ente Público — isso fica fixo na instância, não é algo pra trocar depois sem dor.
2. Se você já tem um Postgres pra usar (aí pede a connection string) ou se quer que ele suba um Postgres local via Docker — útil quando quem está instalando não tem esse banco provisionado ainda.
3. Porta pública (padrão `8080`) e se existe mais de um reverse proxy na frente do gateway — se sim, pede a lista de CIDR/IP confiáveis (`GATEWAY_TRUSTED_PROXY_CIDRS`). Deixar em branco mantém o trust de 1 hop, que é o padrão certo pra topologia de reverse-proxy único.
4. Para onde os eventos recebidos devem ser entregues: um callback HTTP (com a opção de mandar headers extras, ex. um segredo compartilhado), uma fila — RabbitMQ/Kafka/SQS/Redis Streams — (com a opção de customizar o routing key template) ou grava direto num banco de destino. Dá pra pular essa parte e configurar depois, mas até lá toda entrega vai ser rejeitada — o script avisa isso na hora.
5. Se a trilha de auditoria também deve ser gravada no Postgres desta instância (além do stdout, que é o padrão e já basta se o seu coletor de log retém por pelo menos 180 dias).
6. Nível de log (`info` por padrão).
7. Qual tag da imagem usar (por padrão, a mais recente publicada).

A partir daí ele gera o arquivo de configuração, cria o admin token, baixa a imagem, roda a migração do banco, sobe o container do gateway e confere se ele respondeu saudável antes de considerar terminado. No final, imprime o admin token (guarde num gerenciador de segredos assim que aparecer — é a única vez que ele é mostrado) e uma lista do que fazer a seguir: cadastrar o primeiro parceiro, emitir token de cliente se algum frontend for consumir a API, apontar coleta de log, configurar backup do banco — todos via `docker exec` no próprio container, já que a porta administrativa não é alcançável de fora dele.

Qualquer outra configuração do gateway que o script não pergunta (limites de retry, circuit breaker, concorrência de entrega, etc.) já sobe com um valor padrão razoável e pode ser ajustada depois, sem reiniciar a instância, via `pabip-gatewayctl config get`/`config set`.

Só a porta pública fica exposta ao final. A porta administrativa nunca é publicada — de propósito, é assim que a autenticação administrativa foi desenhada pra funcionar com segurança.

## Rastreabilidade e allowlist — o que o reverse proxy não pode mexer

O protocolo PABIP trafega três headers de rastreabilidade de ponta a ponta. O gateway já lida com eles sozinho; o que você precisa garantir é que, ao colocar um reverse proxy na frente (o segundo passo descrito abaixo), ele **repasse esses headers para o upstream sem stripar**:

- `X-Request-Id` — correlaciona uma requisição ao longo de toda a cadeia. O gateway aceita o valor que vier de fora (ou gera um se faltar) e **ecoa `X-Request-Id` em toda resposta**, inclusive nas de erro. É assim que o cliente casa log e resposta.
- `X-Actor-Id` — identifica o operador humano por trás da requisição.
- `X-Case-Ref` — referência do caso/ocorrência que justifica o acesso.

A maioria dos reverse proxies repassa headers desconhecidos por padrão, mas alguns só deixam passar uma allowlist fixa — nesse caso, inclua os três acima explicitamente. Pontos de atenção:

- **nginx**: headers com hífen passam por padrão; não adicione um `proxy_set_header X-Request-Id "";` que os apague. Se você gera o request id no próprio nginx, use `proxy_set_header X-Request-Id $http_x_request_id;` para preservar o valor que o cliente mandou.
- **traefik**: não configure um middleware `headers` que remova esses campos — sem isso, eles passam por padrão.
- **caddy**: `reverse_proxy` repassa todos os headers por padrão; nada a fazer.

### allowlist de IP na abertura de sessão de vídeo

A abertura de sessão de vídeo aceita, no corpo, o campo `allowlist` (`allowlist: string[]`) — uma lista de IPs ou CIDRs (v4/v6, incluindo IPv4-mapped IPv6) autorizados a reproduzir aquela sessão. O reverse proxy **não pode dropar o corpo nem esse campo** ao repassar a requisição.

O enforcement casa cada entrada da `allowlist` contra o IP real do cliente. Quando há proxy adicional na frente, esse IP real só é confiável se `GATEWAY_TRUSTED_PROXY_CIDRS` (perguntado no passo de Rede) apontar para os proxies certos — senão o gateway enxerga o IP do proxy, não o do cliente, e a allowlist casa errado.

## O que fica de fora, de propósito

TLS, reverse proxy e múltiplas réplicas não fazem parte deste script — isso é um segundo passo, depois que a primeira instância já está de pé e você decidiu como vai expor a porta pública pra internet de verdade. Rodar de novo contra um container que já existe também não é o objetivo: o script se recusa a continuar se já achar uma instância no ar com o mesmo nome, em vez de arriscar sobrescrever alguma coisa.

## Licença

Apache-2.0.
