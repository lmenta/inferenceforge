terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.region
}

locals {
  cluster_name = "inferenceforge-${var.environment}"
  common_tags  = { Project = "inferenceforge", Environment = var.environment, ManagedBy = "terraform" }
}

# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.region}a", "${var.region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true  # cost optimisation

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1, "karpenter.sh/discovery" = local.cluster_name }
  tags = local.common_tags
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = "1.29"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  # System node group (CPU) — always on, cheap
  eks_managed_node_groups = {
    system = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 3
      desired_size   = 2
      labels         = { role = "system" }
    }
  }

  tags = local.common_tags
}

# ── GPU Node Group ────────────────────────────────────────────────────────────
resource "aws_eks_node_group" "gpu" {
  cluster_name    = module.eks.cluster_name
  node_group_name = "gpu-workers"
  node_role_arn   = module.eks.eks_managed_node_groups["system"].iam_role_arn
  subnet_ids      = module.vpc.private_subnets

  # g4dn.xlarge: 1x NVIDIA T4, 4 vCPUs, 16 GB RAM — best price/perf for inference
  instance_types = [var.gpu_instance_type]

  scaling_config {
    desired_size = 0           # scale to 0 when idle = $0 cost
    min_size     = 0
    max_size     = var.gpu_max_nodes
  }

  # Spot instances = ~70% cheaper than on-demand
  capacity_type = var.use_spot ? "SPOT" : "ON_DEMAND"

  # Taint GPU nodes so only GPU-requesting pods schedule here
  taint {
    key    = "nvidia.com/gpu"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = {
    role                              = "gpu"
    "k8s.amazonaws.com/accelerator"  = "nvidia-tesla-t4"
  }

  tags = merge(local.common_tags, {
    "karpenter.sh/discovery" = local.cluster_name
  })
}

# ── Karpenter (GPU autoscaler) ────────────────────────────────────────────────
resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "0.37.0"
  namespace  = "karpenter"

  set { name = "settings.clusterName";     value = module.eks.cluster_name }
  set { name = "settings.clusterEndpoint"; value = module.eks.cluster_endpoint }
  set { name = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
        value = aws_iam_role.karpenter.arn }
}

resource "aws_iam_role" "karpenter" {
  name = "${local.cluster_name}-karpenter"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
  tags = local.common_tags
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "cluster_name"     { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}
