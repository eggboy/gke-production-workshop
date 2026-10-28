# The same three inputs as section 1 of env.sh. Every other name and setting is
# derived from them in main.tf, exactly like section 2 of env.sh.

variable "project_id" {
  description = "ID of the Google Cloud project for the workshop (PROJECT_ID in env.sh)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "The project_id must be a valid project ID: 6-30 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "region" {
  description = "Region for every regional resource (REGION in env.sh)."
  type        = string
  default     = "asia-southeast1"
}

variable "prefix" {
  description = "Prefix of every resource name (PREFIX in env.sh)."
  type        = string
  default     = "gkews"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{0,9}$", var.prefix))
    error_message = "The prefix must be 1-10 lowercase letters/digits and start with a letter (the same rule as in env.sh)."
  }
}
