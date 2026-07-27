declare const process: {
  readonly platform: string
  readonly arch: string
  readonly env: Record<string, string | undefined>
  readonly versions: Record<string, string | undefined>
  readonly report?: {
    getReport(): {
      header?: {
        glibcVersionRuntime?: string
        musl?: unknown
      }
    }
  }
}

declare module "node:fs" {
  export function existsSync(path: string): boolean
  export function rmSync(path: string, options?: { recursive?: boolean; force?: boolean }): void
}

declare module "node:module" {
  export function createRequire(url: string): (specifier: string) => unknown
}

declare module "node:url" {
  export function fileURLToPath(url: URL): string
}
