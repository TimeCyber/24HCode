export function createAuth(expectedToken: string) {
  return {
    extractToken(header?: string, queryToken?: string | string[]): string | null {
      if (queryToken) {
        return Array.isArray(queryToken) ? queryToken[0] ?? null : queryToken;
      }
      if (header?.startsWith("Bearer ")) {
        return header.slice(7).trim();
      }
      return null;
    },
    isValid(token: string | null | undefined): boolean {
      if (!expectedToken) return true;
      return Boolean(token && token === expectedToken);
    },
  };
}
