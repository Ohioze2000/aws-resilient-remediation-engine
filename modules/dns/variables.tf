variable "domain_name" {
  type        = string
  description = "The apex domain name registered in Route 53."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Standard tags map for consistency across resources."
}
