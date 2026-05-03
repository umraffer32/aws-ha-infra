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
  source                  = "./modules/compute"
  project_name            = var.project_name
  vpc_id                  = module.network.vpc_id
  azs                     = local.azs
  public_subnet_ids       = module.network.public_subnet_ids
  private_subnet_ids      = module.network.private_subnet_ids
  private_route_table_ids = module.network.private_route_table_ids
  nat_ami_id              = data.aws_ami.nat.id
  nat_instance_type       = "t2.micro"
  private_ami_id          = data.aws_ami.private_baked.id
  private_instance_type   = "t2.micro"
  iam_instance_profile    = "SSM-EC2"
}

module "monitoring" {
  source = "./modules/monitoring"

  project_name                     = var.project_name
  nat_route_healer_lambda_name     = module.nat_route_healer.lambda_name
  nat_route_healer_event_rule_name = module.nat_route_healer.event_rule_name
}

module "nat_route_healer" {
  source = "./modules/nat_route_healer"

  project_name = var.project_name
  nat_asg_to_private_route_table = {
    for idx, asg_name in module.compute.nat_asg_names :
    asg_name => module.network.private_route_table_ids[idx]
  }
}
