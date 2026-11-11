import { execFileSync } from 'child_process';
import * as path from 'path';

describe('git pod credentials (integration)', () => {
  it('runs shell integration tests against configure_git_auth and the credential helper', () => {
    const script = path.join(__dirname, '../../test/git-auth.integration.sh');
    execFileSync('sh', [script], {
      stdio: 'pipe',
      encoding: 'utf8',
      timeout: 240000,
      env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null' },
    });
  }, 300000);
});
