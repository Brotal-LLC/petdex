"use client";

import Link from "next/link";

import { Button } from "@/components/ui/button";

type SubmitCTAProps = {
  className?: string;
  children?: React.ReactNode;
  href?: string;
  variant?: "petdex-cta" | "petdex-secondary" | "petdex-inverse";
};

const DEFAULT_CLASS = "";

export function SubmitCTA({
  className = DEFAULT_CLASS,
  children = "Submit a pet",
  href = "/submit",
  variant = "petdex-cta",
}: SubmitCTAProps) {
  return (
    <Button
      variant={variant}
      size="petdex-pill"
      className={className}
      nativeButton={false}
      render={<Link href={href} prefetch={false} />}
    >
      {children}
    </Button>
  );
}
