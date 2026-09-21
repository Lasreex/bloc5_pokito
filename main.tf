terraform {
  backend "s3" {
    bucket = "pokito-tf-state-lasreex-250832562692-eu-west-3-an"
    key    = "infrastructure/terraform.tfstate"
    region = "eu-west-3"
  }
}

provider "aws" {
  region = "eu-west-3" # Paris
}

# --- RÉSEAU (VPC & Subnets) ---
resource "aws_vpc" "pokito_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "pokito-vpc" }
}

resource "aws_subnet" "public_dmz" {
  vpc_id                  = aws_vpc.pokito_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true # IP publique auto
  tags = { Name = "pokito-public-dmz" }
}

resource "aws_subnet" "private_swarm" {
  vpc_id                  = aws_vpc.pokito_vpc.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = false # Sécurité : Aucune IP publique
  tags = { Name = "pokito-private-swarm" }
}

# Le 2ème sous-réseau public obligatoire pour l'ALB AWS
resource "aws_subnet" "public_dmz_2" {
  vpc_id                  = aws_vpc.pokito_vpc.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = "eu-west-3b" # Zone B différente de la Zone A !
  map_public_ip_on_launch = true
  tags                    = { Name = "pokito-public-dmz-2" }
}

# --- PASSERELLES ET ROUTAGE ---
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.pokito_vpc.id
}

resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_dmz.id
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.pokito_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_dmz.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_assoc_2" {
  subnet_id      = aws_subnet.public_dmz_2.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.pokito_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private_swarm.id
  route_table_id = aws_route_table.private_rt.id
}


################################### --- SECURITY GROUPS --- #######################################

resource "aws_security_group" "sg_alb" {
  name        = "pokito-sg-alb"
  description = "Autorise HTTP entrant"
  vpc_id      = aws_vpc.pokito_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ingress {
  #   from_port   = 1936
  #   to_port     = 1936
  #   protocol    = "tcp"
  #   cidr_blocks = ["0.0.0.0/0"]
  # }

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "sg_swarm" {
  name        = "pokito-sg-swarm"
  description = "Trafic interne uniquement"
  vpc_id      = aws_vpc.pokito_vpc.id

  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.sg_alb.id]
  }

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- GESTION DES ACCÈS SANS SSH (SSM) ---
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm_role" {
  name               = "pokito_ssm_role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "pokito_ssm_profile"
  role = aws_iam_role.ssm_role.name
}

############################ --- MACHINES VIRTUELLES (EC2) --- #############################
data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  owners = ["099720109477"] # Canonical
}

# resource "aws_instance" "haproxy" {
#   ami                  = data.aws_ami.ubuntu.id
#   instance_type        = "t3.micro"
#   subnet_id            = aws_subnet.public_dmz.id
#   vpc_security_group_ids      = [aws_security_group.sg_alb.id]
#   iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

#   tags = { Name = "pokito-haproxy", Role = "proxy" }
# }

resource "aws_instance" "swarm_manager" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = "t3.small"
  subnet_id            = aws_subnet.private_swarm.id
  vpc_security_group_ids      = [aws_security_group.sg_swarm.id]
  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

  tags = { Name = "pokito-swarm-manager", Role = "manager" }
}

resource "aws_instance" "swarm_worker" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = "t3.micro"
  subnet_id            = aws_subnet.private_swarm.id
  vpc_security_group_ids      = [aws_security_group.sg_swarm.id]
  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

  tags = { Name = "pokito-swarm-worker", Role = "worker" }
}

############################ --- AWS ALB --- #############################

resource "aws_lb" "pokito_alb" {
  name               = "pokito-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.sg_alb.id]
  subnets            = [aws_subnet.public_dmz.id, aws_subnet.public_dmz_2.id]
}

# Les "Target Groups"

resource "aws_lb_target_group" "tg_game" {
  name     = "pokito-game-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.pokito_vpc.id
}

resource "aws_lb_target_group" "tg_grafana" {
  name     = "pokito-grafana-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.pokito_vpc.id
}

# Les "Listeners"

resource "aws_lb_listener" "http_game" {
  load_balancer_arn = aws_lb.pokito_alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_game.arn
  }
}

resource "aws_lb_listener" "http_grafana" {
  load_balancer_arn = aws_lb.pokito_alb.arn
  port              = 3000
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_grafana.arn
  }
}

# L'attachement dynamique

resource "aws_lb_target_group_attachment" "game_manager" {
  target_group_arn = aws_lb_target_group.tg_game.arn
  target_id        = aws_instance.swarm_manager.id
}
resource "aws_lb_target_group_attachment" "game_worker" {
  target_group_arn = aws_lb_target_group.tg_game.arn
  target_id        = aws_instance.swarm_worker.id
}
resource "aws_lb_target_group_attachment" "grafana_manager" {
  target_group_arn = aws_lb_target_group.tg_grafana.arn
  target_id        = aws_instance.swarm_manager.id
}
resource "aws_lb_target_group_attachment" "grafana_worker" {
  target_group_arn = aws_lb_target_group.tg_grafana.arn
  target_id        = aws_instance.swarm_worker.id
}

# --- OUTPUTS ---
output "1_application_url" {
  description = "Lien direct vers le jeu Pokito via AWS ALB"
  value       = "http://${aws_lb.pokito_alb.dns_name}"
}

output "2_grafana_url" {
  description = "Lien direct vers Grafana via AWS ALB"
  value       = "http://${aws_lb.pokito_alb.dns_name}:3000"
}