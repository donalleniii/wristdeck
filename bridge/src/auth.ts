import { createHash, timingSafeEqual } from 'node:crypto';
import type { NextFunction, Request, Response } from 'express';
import { CONFIG } from './config.ts';

const expected = createHash('sha256').update(CONFIG.token).digest();

export function requireAuth(req: Request, res: Response, next: NextFunction): void {
  const match = (req.headers.authorization ?? '').match(/^Bearer\s+(\S+)$/i);
  if (match) {
    const got = createHash('sha256').update(match[1]).digest();
    if (timingSafeEqual(got, expected)) {
      next();
      return;
    }
  }
  res.status(401).json({ error: 'unauthorized' });
}
