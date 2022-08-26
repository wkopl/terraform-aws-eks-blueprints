provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = module.eks_blueprints.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks_blueprints.eks_cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks_blueprints.eks_cluster_id
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}

locals {
  name   = basename(path.cwd)
  region = "us-west-2"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}

#---------------------------------------------------------------
# EKS Blueprints
#---------------------------------------------------------------
module "eks_blueprints" {
  source = "../../.."

  cluster_name    = local.name
  cluster_version = "1.22"

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnets

  # https://github.com/aws-ia/terraform-aws-eks-blueprints/issues/485
  # https://github.com/aws-ia/terraform-aws-eks-blueprints/issues/494
  cluster_kms_key_additional_admin_arns = [data.aws_caller_identity.current.arn]

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to Nodegroup all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  managed_node_groups = {
    this = {
      node_group_name = "nvflare"
      instance_types  = ["m5.large"]
      min_size        = 2
      desired_size    = 2
      max_size        = 10
      subnet_ids      = module.vpc.private_subnets
    }
  }

  tags = local.tags
}

module "eks_blueprints_kubernetes_addons" {
  source = "../../../modules/kubernetes-addons"

  eks_cluster_id       = module.eks_blueprints.eks_cluster_id
  eks_cluster_endpoint = module.eks_blueprints.eks_cluster_endpoint
  eks_oidc_provider    = module.eks_blueprints.oidc_provider
  eks_cluster_version  = module.eks_blueprints.eks_cluster_version

  enable_aws_efs_csi_driver = true

  # enable_nvflare = true
  # nvflare_helm_config = {
  #   timeout = 180 # fail fast
  #   set = [
  #     {
  #       name  = "image.repository"
  #       value = var.image_repository
  #       }, {
  #       name  = "image.tag"
  #       value = var.image_tag
  #     },
  #     {
  #       name  = "efsStorageClass.fileSystemId"
  #       value = aws_efs_file_system.this.id
  #     },
  #   ]
  # }

  tags = local.tags
}

#---------------------------------------------------------------
# Fileshare for configs/keys/etc.
#---------------------------------------------------------------

resource "aws_iam_instance_profile" "this" {
  name = local.name
  role = aws_iam_role.this.name
}

resource "aws_iam_role" "this" {
  name_prefix = local.name

  assume_role_policy  = <<-EOF
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Action": "sts:AssumeRole",
                "Principal": {
                  "Service": "ec2.amazonaws.com"
                },
                "Effect": "Allow",
                "Sid": ""
            }
        ]
    }
  EOF
  managed_policy_arns = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]

  tags = local.tags
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-2*-x86_64-gp2"]
  }
}

module "bastion_ec2" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 3.0"

  name = local.name

  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.medium"
  vpc_security_group_ids = [aws_security_group.bastion.id]
  subnet_id              = element(module.vpc.private_subnets, 0)
  iam_instance_profile   = aws_iam_instance_profile.this.name
  user_data_base64 = base64encode(
    <<-EOT
      #!/bin/bash

      WORKDIR=~/workspace

      # Install pipenv
      amazon-linux-extras install epel -y
      yum install python-pip git -y
      python3 -m pip install pipenv

      # Setup EFS mount
      mkdir $WORKDIR
      mount -t nfs -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport ${element(local.azs, 0)}.${aws_efs_file_system.this.dns_name}:/workspace $WORKDIR



      # NVflare
      python3 -m pipenv install -e "git+https://git@github.com/NVIDIA/NVFlare.git@dev#egg=nvflare-nightly"
      printf '\n[scripts]\nprovision = "nvflare provision -p project.yml"\n' >> Pipfile
      # Hack to squeeze large file through userdata
      printf ${filebase64("${path.module}/project.yml")} | base64 --decode > project.yml
      python3 -m pipenv run provision
      mv /workspace/example_project/prod_00/* $${WORKDIR}/
      chmod go+rw $WORKDIR
    EOT
  )

  tags = local.tags
}

resource "aws_security_group" "bastion" {
  name        = "${local.name}-bastion"
  description = "EC2 security group"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "Temp"
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
  }

  tags = local.tags
}

resource "aws_efs_file_system" "this" {
  creation_token = local.name
  encrypted      = true

  tags = local.tags
}

resource "aws_efs_mount_target" "this" {
  count = length(module.vpc.private_subnets)

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.this.id]
}

resource "aws_security_group" "this" {
  name        = "${local.name}-efs"
  description = "EFS security group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "NFS access from private subnets"
    cidr_blocks = module.vpc.private_subnets_cidr_blocks
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
  }

  tags = local.tags
}

#---------------------------------------------------------------
# Supporting Resources
#---------------------------------------------------------------

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 10)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Manage so we can name
  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${local.name}-default" }
  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${local.name}-default" }
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${local.name}-default" }

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/elb"              = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/internal-elb"     = 1
  }

  tags = local.tags
}
