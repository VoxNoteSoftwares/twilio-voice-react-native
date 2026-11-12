import { readJwtExpiry } from '../Voice';
/* eslint-env node */
jest.mock('../common');

function jwt(claims: object): string {
  const encode = (value: object) =>
    Buffer.from(JSON.stringify(value))
      .toString('base64')
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/[=]+$/, '');
  return `${encode({ alg: 'HS256', typ: 'JWT' })}.${encode(claims)}.signature`;
}

describe('readJwtExpiry', () => {
  beforeAll(() => {
    if (typeof (global as any).atob !== 'function') {
      (global as any).atob = (data: string) =>
        Buffer.from(data, 'base64').toString('binary');
    }
  });

  it('returns exp in milliseconds', () => {
    expect(readJwtExpiry(jwt({ exp: 1_800_000_000 }))).toBe(1_800_000_000_000);
  });

  it('returns null without an exp claim', () => {
    expect(readJwtExpiry(jwt({ sub: 'x' }))).toBeNull();
  });

  it('returns null for a malformed token', () => {
    expect(readJwtExpiry('not-a-jwt')).toBeNull();
  });
});
