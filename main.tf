data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "network" {
  source = "./modules/network"

  project_name = var.project_name
  azs          = local.azs
}

module "compute" {
  source = "./modules/compute"
  project_name            = var.project_name
  vpc_id                  = module.network.vpc_id
  azs                     = local.azs
  public_subnet_ids       = module.network.public_subnet_ids
  private_subnet_ids      = module.network.private_subnet_ids
  private_route_table_ids = module.network.private_route_table_ids
  nat_ami_id              = data.aws_ami.debian.id
  nat_instance_type       = "t2.micro"
  private_ami_id          = data.aws_ami.ubuntu.id
  private_instance_type   = "t2.micro"
  iam_instance_profile    = "SSM-EC2"
}
