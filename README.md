# pabip-gateway-installer

Um script só, pra subir uma instância nova do pabip-gateway sem precisar clonar repositório, instalar dependência nenhuma além de Docker e responder umas perguntas no terminal.

O pabip-gateway é a implementação de referência do protocolo PABIP — a ponte self-hosted entre quem produz eventos de analítico de imagem (Ente Privado, câmeras/sensores) e quem consome (sistema do Ente Público, via callback, fila ou banco). A previsão é publicar o código dele também nesta organização em breve; até lá, este repo cobre só o instalador.

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
3. Para onde os eventos recebidos devem ser entregues: um callback HTTP, uma fila (RabbitMQ/Kafka/SQS/Redis Streams) ou grava direto num banco de destino. Dá pra pular essa parte e configurar depois, mas até lá toda entrega vai ser rejeitada — o script avisa isso na hora.
4. Qual tag da imagem usar (por padrão, a mais recente publicada).

A partir daí ele gera o arquivo de configuração, cria o admin token, baixa a imagem, roda a migração do banco, sobe o container do gateway e confere se ele respondeu saudável antes de considerar terminado. No final, imprime o admin token (guarde num gerenciador de segredos assim que aparecer — é a única vez que ele é mostrado) e uma lista do que fazer a seguir: cadastrar o primeiro parceiro, emitir token de cliente se algum frontend for consumir a API, apontar coleta de log, configurar backup do banco.

Só a porta pública (8080) fica exposta ao final. A porta administrativa nunca é publicada — de propósito, é assim que a autenticação administrativa foi desenhada pra funcionar com segurança.

## O que fica de fora, de propósito

TLS, reverse proxy e múltiplas réplicas não fazem parte deste script — isso é um segundo passo, depois que a primeira instância já está de pé e você decidiu como vai expor a porta pública pra internet de verdade. Rodar de novo contra um container que já existe também não é o objetivo: o script se recusa a continuar se já achar uma instância no ar com o mesmo nome, em vez de arriscar sobrescrever alguma coisa.

## Licença

Apache-2.0.
