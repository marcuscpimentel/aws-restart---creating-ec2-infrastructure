# Introduction to Amazon EC2

No contexto do programa AWS re/Start, oferecido pela parceria entre a AWS e a Escola da Nuvem, realizei o laboratório **Introduction to Amazon EC2**, com criação, monitoramento e redimensionamento de uma instância.

Fiz o laboratório primeiro pelo console da AWS. Depois, escrevi a infraestrutura em Terraform e preparei os testes para conferir as configurações e o funcionamento do servidor web.

Abaixo estão as etapas do exercício e os principais trechos da implementação. As referências a variáveis e outros recursos fazem parte dos arquivos deste repositório; os blocos não são arquivos independentes.

## Configurações gerais da instância

O laboratório começa com a criação de uma instância para hospedar uma página web. A configuração inicial usa:

- Amazon Linux 2023;
- instância `t3.micro`;
- volume raiz de 8 GiB;
- sub-rede da Lab VPC;
- nenhum par de chaves para SSH;
- proteção contra término habilitada.

No Terraform, a instância é definida pelo recurso `aws_instance`. Este é o trecho com as configurações principais:

```hcl
resource "aws_instance" "web" {
  ami                         = var.ami_id != null ? var.ami_id : nonsensitive(data.aws_ssm_parameter.al2023[0].value)
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.web.id]
  associate_public_ip_address = true
  disable_api_termination     = var.termination_protection
  monitoring                  = false
  user_data                   = file("${path.module}/scripts/user-data.sh")
  user_data_replace_on_change = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }
}
```

O tipo da máquina, o tamanho do disco e a proteção contra término vêm de variáveis. Na primeira etapa, os valores são:

```hcl
instance_type          = "t3.micro"
root_volume_size       = 8
allow_http             = false
termination_protection = true
```

O atributo `associate_public_ip_address` solicita um IPv4 público para a instância. Já `vpc_security_group_ids` associa o Security Group que controla o acesso ao servidor.

No volume raiz, o código especifica `gp3`, criptografia e exclusão do disco junto com o término da EC2. A ausência de `key_name` corresponde ao exercício, que não exige login por SSH.

No console, a rede já estava disponível na Lab VPC. Para usar uma rede existente na versão Terraform, o projeto recebe o ID da sub-rede em `existing_subnet_id`. Quando essa variável não é informada, ele cria uma VPC e uma sub-rede pública, com Internet Gateway e rota de saída.

## Instalação e inicialização do servidor web

A instalação do Apache é feita pelo user data, executado na primeira inicialização da instância. No projeto, deixei esse script em `scripts/user-data.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

dnf install -y httpd

cat > /var/www/html/index.html <<'HTML'
<!doctype html>
<html lang="pt-BR">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>EC2 Lab</title>
  </head>
  <body>
    <h1>Servidor EC2 em funcionamento</h1>
    <p id="lab-marker">ec2-lab-ready</p>
    <p>Amazon Linux 2023, Apache e Terraform.</p>
  </body>
</html>
HTML

chmod 0644 /var/www/html/index.html
systemctl enable --now httpd
```

O `dnf` instala o pacote `httpd`. Em seguida, o script cria a página no diretório servido pelo Apache. O comando `systemctl enable --now httpd` inicia o serviço e o habilita para as próximas inicializações.

A linha `user_data = file(...)`, na configuração da EC2, lê esse arquivo e envia seu conteúdo para a instância. O marcador `ec2-lab-ready` na página é usado depois no teste HTTP para conferir o conteúdo retornado.

## Monitoramento da instância

Depois da criação, o laboratório pede a verificação dos status checks e das métricas de monitoramento no console.

Os status checks ajudam a identificar problemas na infraestrutura que sustenta a EC2 e na própria instância. No CloudWatch, é possível acompanhar métricas como utilização de CPU e tráfego de rede.

Na implementação, mantive o monitoramento básico:

```hcl
monitoring = false
```

No recurso `aws_instance`, esse atributo controla o monitoramento **detalhado**. Portanto, `false` mantém o monitoramento básico, com métricas em intervalos de cinco minutos. O detalhado utiliza intervalos de um minuto.

Os testes de integração também aguardam a aprovação dos status checks. A consulta aos pontos de CPU no CloudWatch ficou como uma verificação opcional, porque essas métricas podem levar alguns minutos para aparecer.

## Alteração do Security Group para liberar HTTP

Na configuração inicial, o Security Group não possui regras de entrada. Por isso, o acesso à página pela porta 80 fica bloqueado, mesmo com a instância em execução.

No console, essa etapa consiste em adicionar uma regra de entrada para HTTP, permitindo conexões de qualquer endereço IPv4. No Terraform, a regra depende de `allow_http`:

```hcl
ingress = var.allow_http ? [{
  description      = "HTTP"
  from_port        = 80
  to_port          = 80
  protocol         = "tcp"
  cidr_blocks      = [var.http_cidr]
  ipv6_cidr_blocks = []
  prefix_list_ids  = []
  security_groups  = []
  self             = false
}] : []
```

Esse trecho fica dentro de `aws_security_group.web`. Quando `allow_http` é `false`, a lista de regras de entrada fica vazia. Quando passa para `true`, o Terraform configura a entrada TCP na porta 80.

A origem vem de `http_cidr`, cujo valor padrão é `0.0.0.0/0`, reproduzindo a liberação pública do exercício. O acesso SSH continua sem regra de entrada.

O arquivo `scenarios/02-http.tfvars` altera `allow_http` para `true`, mantendo o tipo da instância, o tamanho do disco e a proteção contra término. Depois de aplicar essa etapa e aguardar a instalação do Apache, o endereço pode ser consultado com:

```bash
terraform output -raw web_url
```

## Alteração do tipo da instância e do volume EBS

A etapa seguinte aumenta a capacidade da EC2 e o tamanho do disco:

| Recurso | Configuração inicial | Após a alteração |
| --- | --- | --- |
| Instância | t3.micro | t3.small |
| Memória | 1 GiB | 2 GiB |
| Volume raiz | 8 GiB | 10 GiB |

Pelo console, o procedimento envolve parar a instância, alterar seu tipo, aumentar o volume e iniciar a máquina novamente.

Na versão Terraform, os novos valores ficam em `scenarios/03-resized.tfvars`:

```hcl
instance_type          = "t3.small"
root_volume_size       = 10
allow_http             = true
termination_protection = true
```

Essas variáveis alimentam `instance_type` e `root_block_device.volume_size` no recurso da EC2. Para revisar e aplicar a mudança:

```bash
terraform plan -var-file=scenarios/03-resized.tfvars -out=resized.tfplan
terraform apply resized.tfplan
```

A alteração do tipo envolve stop/start, com interrupção do serviço. O plano deve indicar a atualização da instância existente para essa mudança. Como o IPv4 público pode mudar quando a máquina volta, é necessário consultar a saída `web_url` novamente.

O teste do volume verifica se a AWS informa 10 GiB para o EBS. A expansão da partição e do sistema de arquivos dentro da instância exige uma verificação própria e ficou fora do escopo desse teste.

## Proteção contra término e remoção dos recursos

A proteção contra término é habilitada desde a criação. No console, o laboratório inclui uma tentativa de terminar a instância com essa proteção ativa, seguida da desativação para permitir sua exclusão.

No Terraform, o atributo correspondente é:

```hcl
disable_api_termination = var.termination_protection
```

Com `termination_protection = true`, o EC2 bloqueia o término pela API. Essa proteção permite a parada da instância, necessária durante a alteração de tipo.

Para preparar a remoção depois do resize, o arquivo `scenarios/04-cleanup.tfvars` mantém as configurações da máquina e desativa a proteção:

```hcl
instance_type          = "t3.small"
root_volume_size       = 10
allow_http             = true
termination_protection = false
```

A mudança precisa ser aplicada antes da remoção:

```bash
terraform apply -var-file=scenarios/04-cleanup.tfvars
terraform destroy -var-file=scenarios/04-cleanup.tfvars
```

O primeiro comando atualiza o atributo na EC2. O segundo remove os recursos gerenciados pelo projeto. Quando uma sub-rede existente é utilizada, a rede fornecida fica fora da remoção.

## Testes da implementação

Além da infraestrutura, preparei testes para verificar as configurações previstas em cada etapa e consultar os recursos após uma implantação.

Os testes nativos do Terraform usam um provider AWS simulado. Um dos cenários verifica os parâmetros do resize:

```hcl
run "resized_state" {
  command = plan

  variables {
    allow_http       = true
    instance_type    = "t3.small"
    root_volume_size = 10
  }

  assert {
    condition = (
      aws_instance.web.instance_type == "t3.small" &&
      aws_instance.web.root_block_device[0].volume_size == 10
    )
    error_message = "A etapa de resize deve usar t3.small e EBS de 10 GiB."
  }
}
```

O bloco define as entradas desse cenário e confere os valores no plano. Ele faz parte de `tests/lab.tftest.hcl`, que contém a configuração do provider simulado e os outros cenários. A execução é feita com `terraform test`, sem criar recursos na AWS.

Já `tests/integration.py` consulta a conta AWS para verificar o tipo e o estado da instância, o EBS, as regras do Security Group e a proteção contra término. Nas etapas com HTTP liberado, também exige uma resposta 200 contendo o marcador da página.

Depois de aplicar a etapa de resize, por exemplo, a execução usa:

```bash
terraform output -json > terraform-outputs.json
python tests/integration.py --stage resized
```

O arquivo de saídas fornece os identificadores dos recursos. O argumento `--stage resized` define os valores esperados para essa etapa. Esse teste consulta a proteção contra término pelo atributo da instância, sem executar uma tentativa de exclusão.

Nesta versão, passaram as verificações de formatação, sintaxe e os três testes locais do verificador HTTP. A validação completa do Terraform ficou bloqueada por uma restrição de sockets do ambiente utilizado, e os testes de integração contra a AWS ainda precisam ser executados.

Os comandos de preparação, execução das etapas e instalação das dependências dos testes estão em [docs/usage.md](docs/usage.md). Os resultados das verificações desta versão estão em [VALIDATION.md](VALIDATION.md).
