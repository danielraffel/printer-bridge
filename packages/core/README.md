# Core Package

This directory is reserved for platform-agnostic logic.

Expected responsibilities:
- printer and queue models
- AirPrint capability mapping
- TXT record generation
- bridge configuration models
- shared diagnostics structures

The goal is to keep as much logic here as possible so future Linux support is an additive platform layer, not a rewrite.
