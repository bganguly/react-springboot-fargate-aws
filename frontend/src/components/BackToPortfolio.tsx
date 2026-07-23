export default function BackToPortfolio() {
  function handleBack(e: React.MouseEvent<HTMLAnchorElement>) {
    e.preventDefault();
    const url = 'https://bganguly.github.io/#fargate';
    try {
      if (window.opener && !window.opener.closed) {
        window.opener.location.href = url;
        window.close();
        return;
      }
    } catch (_) {}
    window.location.href = url;
  }
  return (
    <a
      href="https://bganguly.github.io/#fargate"
      onClick={handleBack}
      style={{
        position: 'fixed',
        top: '12px',
        left: '12px',
        zIndex: 50,
        display: 'inline-flex',
        alignItems: 'center',
        gap: '4px',
        padding: '6px 12px',
        borderRadius: '6px',
        fontSize: '12px',
        fontWeight: 500,
        textDecoration: 'none',
        background: 'rgba(0,0,0,0.65)',
        border: '1px solid rgba(255,255,255,0.12)',
        color: '#d4d4d8',
        transition: 'color 0.15s',
      }}
      onMouseEnter={e => (e.currentTarget.style.color = '#fff')}
      onMouseLeave={e => (e.currentTarget.style.color = '#d4d4d8')}
    >
      ← Portfolio
    </a>
  );
}
