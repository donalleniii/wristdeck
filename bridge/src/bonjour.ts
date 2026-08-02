import { Bonjour } from 'bonjour-service';
import { CONFIG } from './config.ts';

export function advertise(): void {
  try {
    const bonjour = new Bonjour();
    const service = bonjour.publish({ name: 'WristDeck Bridge', type: 'wristdeck', port: CONFIG.port });
    const stop = (): void => {
      try {
        service.stop?.(() => undefined);
        bonjour.destroy();
      } finally {
        process.exit(0);
      }
    };
    process.on('SIGINT', stop);
    process.on('SIGTERM', stop);
    console.log(`[bonjour] advertising _wristdeck._tcp on port ${CONFIG.port}`);
  } catch (err) {
    console.warn('[bonjour] advertise failed (non-fatal):', err);
  }
}
