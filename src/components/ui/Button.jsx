export default function Button({ variant = 'primary', size, className = '', children, ...rest }) {
  const cls = [
    'btn',
    variant === 'primary' && 'btn-primary',
    variant === 'secondary' && 'btn-secondary',
    variant === 'danger' && 'btn-danger',
    variant === 'danger-ghost' && 'btn-danger-ghost',
    variant === 'ghost' && 'btn-ghost',
    size === 'sm' && 'btn-sm',
    size === 'lg' && 'btn-lg',
    rest.block && 'btn-block',
    className,
  ]
    .filter(Boolean)
    .join(' ')

  return (
    <button className={cls} {...rest}>
      {children}
    </button>
  )
}
