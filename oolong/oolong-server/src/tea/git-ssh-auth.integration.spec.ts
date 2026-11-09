import { execFileSync } from 'child_process';
import * as path from 'path';

describe('git pod ssh deploy key (integration)', () => {
  it('runs shell integration tests against an unprivileged sshd', () => {
    const script = path.join(
      __dirname,
      '../../test/git-ssh-auth.integration.sh',
    );
    execFileSync('sh', [script], {
      stdio: 'pipe',
      encoding: 'utf8',
      timeout: 240000,
      env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null' },
    });
  }, 300000);
});
