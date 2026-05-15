variable "region"            { default = "eu-west-2" }         # London
variable "environment"       { default = "dev" }
variable "gpu_instance_type" { default = "g4dn.xlarge" }       # 1x T4, cheapest GPU
variable "gpu_max_nodes"     { default = 2 }
variable "use_spot"          { default = true }                 # Spot = ~70% cheaper
